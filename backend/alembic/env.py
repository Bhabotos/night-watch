"""Alembic environment.

The database URL comes from the same DB_* environment variables as the app, so
migrations run with the application role (never a superuser). Tests can hand in
an existing connection through config.attributes["connection"].
"""

from alembic import context
from app.config import get_settings
from app.core.logging import setup_logging
from app.db.base import Base
from app.db.models import Task  # noqa: F401  (registers the model on Base.metadata)

config = context.config
target_metadata = Base.metadata


def run_migrations(connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    connection = config.attributes.get("connection")
    if connection is not None:
        run_migrations(connection)
        return

    from app.db.session import create_db_engine

    settings = get_settings()
    setup_logging(settings.log_level, secrets=[settings.db_password.get_secret_value()])
    engine = create_db_engine(settings)
    try:
        with engine.connect() as conn:
            run_migrations(conn)
    finally:
        engine.dispose()


if context.is_offline_mode():
    raise RuntimeError("Offline (SQL script) mode is not supported; run against a database.")
run_migrations_online()
