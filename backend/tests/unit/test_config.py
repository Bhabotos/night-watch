import pytest
from pydantic import ValidationError

from app.config import Settings


def test_database_settings_are_required(monkeypatch):
    for name in ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASSWORD"):
        monkeypatch.delenv(name, raising=False)
    with pytest.raises(ValidationError) as exc:
        Settings(_env_file=None)
    missing = {e["loc"][0] for e in exc.value.errors()}
    assert {"db_host", "db_name", "db_user", "db_password"} <= missing


def test_settings_read_from_environment(monkeypatch):
    monkeypatch.setenv("DB_HOST", "postgres")
    monkeypatch.setenv("DB_NAME", "tasks")
    monkeypatch.setenv("DB_USER", "tasks_app")
    monkeypatch.setenv("DB_PASSWORD", "env-secret")
    settings = Settings(_env_file=None)
    assert settings.db_host == "postgres"
    assert settings.database_url.drivername == "postgresql+psycopg"
    assert settings.database_url.password == "env-secret"


def test_password_is_never_rendered(settings):
    assert "unit-test-password" not in repr(settings)
    assert "unit-test-password" not in str(settings)
    assert "unit-test-password" not in settings.database_url.render_as_string()
    assert "unit-test-password" not in repr(settings.database_url)
