import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from prometheus_client import CollectorRegistry, GCCollector, PlatformCollector, ProcessCollector
from sqlalchemy import Engine

from app.api import routes_health, routes_tasks
from app.config import Settings, get_settings
from app.core.errors import register_exception_handlers
from app.core.logging import setup_logging
from app.core.metrics import Metrics
from app.core.middleware import ObservabilityMiddleware
from app.db.session import create_db_engine, ensure_not_superuser, make_session_factory

logger = logging.getLogger(__name__)


def create_app(settings: Settings | None = None, engine: Engine | None = None) -> FastAPI:
    settings = settings or get_settings()
    setup_logging(settings.log_level, secrets=[settings.db_password.get_secret_value()])
    engine = engine or create_db_engine(settings)

    registry = CollectorRegistry()
    ProcessCollector(registry=registry)
    PlatformCollector(registry=registry)
    GCCollector(registry=registry)
    metrics = Metrics(registry)
    metrics.instrument_engine(engine)

    @asynccontextmanager
    async def lifespan(_: FastAPI) -> AsyncIterator[None]:
        if engine.dialect.name == "postgresql":
            ensure_not_superuser(engine)
        logger.info("backend started")
        yield
        engine.dispose()
        logger.info("backend stopped")

    app = FastAPI(title="Tasks API", version="1.0.0", lifespan=lifespan)
    app.state.settings = settings
    app.state.engine = engine
    app.state.session_factory = make_session_factory(engine)
    app.state.metrics = metrics

    app.add_middleware(ObservabilityMiddleware, metrics=metrics)
    register_exception_handlers(app)
    app.include_router(routes_health.router)
    app.include_router(routes_tasks.router)
    return app
