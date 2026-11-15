"""Integration tests against the real PostgreSQL service.

They need the DB_* environment variables and network access to PostgreSQL, so they
run inside the compose `backend-test` service (application network). Each test run
works in its own throw-away schema inside the application database; the real
`public.tasks` table and its data are never touched.
"""

import os
import uuid
from pathlib import Path

import pytest
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.runtime.migration import MigrationContext
from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine, inspect, text
from sqlalchemy.exc import IntegrityError

from alembic import command
from app.config import Settings
from app.db.base import Base
from app.main import create_app

pytestmark = pytest.mark.integration

ROOT = Path(__file__).resolve().parents[2]
URL = "/api/v1/tasks"


@pytest.fixture(scope="module")
def pg_settings() -> Settings:
    if "DB_HOST" not in os.environ:
        pytest.skip("DB_* environment not set: run via `docker compose run --rm backend-test`")
    return Settings()


@pytest.fixture
def schema_engine(pg_settings):
    """An engine whose search_path is a fresh schema, dropped afterwards."""
    schema = f"test_{uuid.uuid4().hex[:12]}"
    admin = create_engine(pg_settings.database_url)
    with admin.begin() as conn:
        conn.execute(text(f'CREATE SCHEMA "{schema}"'))
    engine = create_engine(
        pg_settings.database_url,
        connect_args={"options": f"-c search_path={schema}", "connect_timeout": 5},
    )
    yield engine
    engine.dispose()
    with admin.begin() as conn:
        conn.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
    admin.dispose()


def alembic_config(connection) -> Config:
    config = Config(str(ROOT / "alembic.ini"))
    config.set_main_option("script_location", str(ROOT / "alembic"))
    config.attributes["connection"] = connection
    return config


def migrate(engine: Engine, action: str, revision: str) -> None:
    with engine.connect() as conn:
        getattr(command, action)(alembic_config(conn), revision)
        conn.commit()


@pytest.fixture
def migrated_engine(schema_engine):
    migrate(schema_engine, "upgrade", "head")
    return schema_engine


# ---- migrations -----------------------------------------------------------------------------


def test_upgrade_creates_expected_schema(migrated_engine):
    inspector = inspect(migrated_engine)
    assert {"tasks", "alembic_version"} <= set(inspector.get_table_names(schema=None))
    columns = {c["name"]: c for c in inspector.get_columns("tasks")}
    assert set(columns) == {"id", "title", "description", "status", "created_at", "updated_at"}
    assert columns["title"]["nullable"] is False
    assert columns["description"]["nullable"] is True
    indexes = {i["name"] for i in inspector.get_indexes("tasks")}
    assert {"ix_tasks_status", "ix_tasks_created_at"} <= indexes
    with migrated_engine.connect() as conn:
        assert conn.execute(text("SELECT version_num FROM alembic_version")).scalar() == "0001"


def test_migration_matches_models(migrated_engine):
    """No drift: autogenerate finds nothing to change."""
    with migrated_engine.connect() as conn:
        diff = compare_metadata(MigrationContext.configure(conn), Base.metadata)
    assert diff == []


def test_downgrade_removes_tables_and_upgrade_is_repeatable(schema_engine):
    migrate(schema_engine, "upgrade", "head")
    migrate(schema_engine, "downgrade", "base")
    assert "tasks" not in inspect(schema_engine).get_table_names()
    migrate(schema_engine, "upgrade", "head")
    migrate(schema_engine, "upgrade", "head")  # idempotent
    assert "tasks" in inspect(schema_engine).get_table_names()


def test_check_constraint_rejects_invalid_status(migrated_engine):
    with migrated_engine.begin() as conn, pytest.raises(IntegrityError):
        conn.execute(text("INSERT INTO tasks (title, status) VALUES ('x', 'bogus')"))


# ---- application against PostgreSQL ---------------------------------------------------------


@pytest.fixture
def pg_client(pg_settings, migrated_engine):
    with TestClient(create_app(pg_settings, migrated_engine)) as client:
        yield client


def test_application_role_is_not_a_superuser(migrated_engine):
    with migrated_engine.connect() as conn:
        assert (
            conn.execute(
                text("SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
            ).scalar()
            is False
        )


def test_crud_roundtrip_on_postgres(pg_client):
    created = pg_client.post(URL, json={"title": "pg", "description": "d"}).json()
    assert created["status"] == "todo"
    updated = pg_client.patch(f"{URL}/{created['id']}", json={"status": "done"}).json()
    assert updated["status"] == "done"
    assert updated["updated_at"] >= created["updated_at"]
    assert pg_client.get(URL, params={"status": "done"}).json()["total"] == 1
    assert pg_client.delete(f"{URL}/{created['id']}").status_code == 204
    assert pg_client.get(f"{URL}/{created['id']}").status_code == 404


def test_updated_at_advances_on_update(pg_client):
    task = pg_client.post(URL, json={"title": "t"}).json()
    after = pg_client.put(f"{URL}/{task['id']}", json={"title": "t2"}).json()
    assert after["updated_at"] > task["updated_at"]
    assert after["created_at"] == task["created_at"]


def test_ready_and_metrics_on_postgres(pg_client):
    pg_client.post(URL, json={"title": "counted", "status": "in_progress"})
    assert pg_client.get("/ready").json() == {"status": "ready", "database": "ok"}
    text_ = pg_client.get("/metrics").text
    assert 'tasks_count{status="in_progress"} 1.0' in text_
    assert 'db_query_duration_seconds_count{operation="insert"}' in text_
    assert 'db_pool_connections{state="checked_out"}' in text_


def test_database_down_gives_503_not_a_crash(pg_settings):
    unreachable = Settings(
        db_host=pg_settings.db_host,
        db_port=1,
        db_name=pg_settings.db_name,
        db_user=pg_settings.db_user,
        db_password=pg_settings.db_password,
        db_connect_timeout_s=1,
    )
    with TestClient(create_app(unreachable), raise_server_exceptions=False) as client:
        assert client.get("/health").status_code == 200
        assert client.get("/ready").status_code == 503
        response = client.get(URL)
        assert response.status_code == 503
        assert response.json()["error"]["code"] == "database_unavailable"
        assert client.get("/metrics").status_code == 200  # scrape survives a DB outage
        assert "tasks_count" not in client.get("/metrics").text
