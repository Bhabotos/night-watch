"""Engine and session management.

The engine is created once per application (see app.main.create_app) and is
disposed on shutdown. Sessions are request-scoped via the get_db dependency.
"""

import logging
from collections.abc import Iterator

from fastapi import Request
from sqlalchemy import Engine, create_engine, text
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings

logger = logging.getLogger(__name__)


def create_db_engine(settings: Settings) -> Engine:
    return create_engine(
        settings.database_url,
        pool_size=settings.db_pool_size,
        max_overflow=settings.db_max_overflow,
        pool_timeout=settings.db_pool_timeout_s,
        pool_pre_ping=True,
        pool_recycle=1800,
        connect_args={
            "connect_timeout": settings.db_connect_timeout_s,
            "application_name": "tasks-backend",
            "options": f"-c statement_timeout={settings.db_statement_timeout_ms}",
        },
    )


def make_session_factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(bind=engine, expire_on_commit=False)


def get_db(request: Request) -> Iterator[Session]:
    with request.app.state.session_factory() as session:
        yield session


def ensure_not_superuser(engine: Engine) -> None:
    """Refuse to run as a PostgreSQL superuser.

    Skips if the database is down; /ready reports that separately.
    """
    try:
        with engine.connect() as conn:
            is_super = conn.execute(
                text("SELECT rolsuper FROM pg_roles WHERE rolname = current_user")
            ).scalar_one_or_none()
    except Exception as exc:
        logger.warning("startup role check skipped", extra={"error_type": type(exc).__name__})
        return
    if is_super:
        raise RuntimeError("Refusing to start: the database role is a superuser")


def check_database(engine: Engine) -> bool:
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except Exception as exc:
        logger.warning("readiness check failed", extra={"error_type": type(exc).__name__})
        return False
    return True
