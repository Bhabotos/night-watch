from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app.db.session import check_database

router = APIRouter(tags=["operations"])


@router.get("/health")
def health() -> dict[str, str]:
    """Liveness: the process is up and serving. Does not touch the database."""
    return {"status": "ok"}


@router.get("/ready")
def ready(request: Request) -> JSONResponse:
    """Readiness: the database accepts connections. Failure details stay in the logs."""
    if check_database(request.app.state.engine):
        return JSONResponse({"status": "ready", "database": "ok"})
    return JSONResponse({"status": "not_ready", "database": "unavailable"}, status_code=503)


@router.get("/metrics", include_in_schema=False)
def metrics(request: Request) -> Response:
    return Response(
        generate_latest(request.app.state.metrics.registry), media_type=CONTENT_TYPE_LATEST
    )
