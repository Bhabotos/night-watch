import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine
from sqlalchemy.pool import StaticPool

from app.config import Settings
from app.db.base import Base
from app.main import create_app

TEST_PASSWORD = "unit-test-password-123"


@pytest.fixture
def settings() -> Settings:
    return Settings(
        db_host="db.invalid",
        db_name="tasks",
        db_user="tasks_app",
        db_password=TEST_PASSWORD,
        max_page_size=50,
    )


@pytest.fixture
def sqlite_engine() -> Engine:
    """In-memory SQLite: fast API tests with no database service."""
    engine = create_engine(
        "sqlite+pysqlite://",
        poolclass=StaticPool,
        connect_args={"check_same_thread": False},
    )
    Base.metadata.create_all(engine)
    yield engine
    engine.dispose()


@pytest.fixture
def client(capsys, settings: Settings, sqlite_engine: Engine) -> TestClient:
    # capsys first: logging binds to sys.stdout when the app is created.
    with TestClient(create_app(settings, sqlite_engine)) as test_client:
        yield test_client
