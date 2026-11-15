"""Application exceptions and the handlers that turn every failure into one JSON shape.

Response body: {"error": {"code", "message", "request_id", ["details"]}}.
Internal details (SQL, stack traces, connection info) are never returned to clients.
"""

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import OperationalError, SQLAlchemyError
from sqlalchemy.exc import TimeoutError as PoolTimeoutError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.logging import request_id_var

logger = logging.getLogger(__name__)


class AppError(Exception):
    status_code = 500
    code = "internal_error"
    message = "Internal server error"

    def __init__(self, message: str | None = None) -> None:
        super().__init__(message or self.message)
        self.message = message or self.message


class TaskNotFoundError(AppError):
    status_code = 404
    code = "task_not_found"
    message = "Task not found"


def error_response(
    status_code: int, code: str, message: str, details: list[dict[str, Any]] | None = None
) -> JSONResponse:
    body: dict[str, Any] = {
        "code": code,
        "message": message,
        "request_id": request_id_var.get(),
    }
    if details:
        body["details"] = details
    return JSONResponse(status_code=status_code, content={"error": body})


async def app_error_handler(_: Request, exc: AppError) -> JSONResponse:
    return error_response(exc.status_code, exc.code, exc.message)


async def http_exception_handler(_: Request, exc: StarletteHTTPException) -> JSONResponse:
    code = {404: "not_found", 405: "method_not_allowed"}.get(exc.status_code, "http_error")
    return error_response(exc.status_code, code, str(exc.detail))


async def validation_error_handler(_: Request, exc: RequestValidationError) -> JSONResponse:
    # Only location, message and type: the submitted value ("input") is not echoed back.
    details = [
        {
            "field": ".".join(str(p) for p in e["loc"] if p != "body"),
            "message": e["msg"],
            "type": e["type"],
        }
        for e in exc.errors()
    ]
    return error_response(422, "validation_error", "Request validation failed", details)


async def database_error_handler(_: Request, exc: SQLAlchemyError) -> JSONResponse:
    if isinstance(exc, OperationalError | PoolTimeoutError):
        logger.error("database unavailable", extra={"error_type": type(exc).__name__})
        return error_response(503, "database_unavailable", "Database temporarily unavailable")
    logger.exception("database error")
    return error_response(500, "internal_error", "Internal server error")


def register_exception_handlers(app: FastAPI) -> None:
    app.add_exception_handler(AppError, app_error_handler)  # type: ignore[arg-type]
    app.add_exception_handler(StarletteHTTPException, http_exception_handler)  # type: ignore[arg-type]
    app.add_exception_handler(RequestValidationError, validation_error_handler)  # type: ignore[arg-type]
    app.add_exception_handler(SQLAlchemyError, database_error_handler)  # type: ignore[arg-type]
