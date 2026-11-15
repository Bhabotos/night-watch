"""Request-id propagation, access logging and HTTP metrics in one ASGI middleware.

Pure ASGI (not BaseHTTPMiddleware) so streaming, contextvars and exceptions behave
predictably. Unhandled exceptions are logged with a traceback and turned into a
generic 500 here, so clients never see internals and the failure is still counted.
"""

import logging
import re
import time
import uuid

from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.core.errors import error_response
from app.core.logging import request_id_var
from app.core.metrics import Metrics

logger = logging.getLogger("app.access")

_VALID_REQUEST_ID = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
# Polled constantly by Prometheus and container health checks: log at DEBUG.
_QUIET_PATHS = {"/metrics", "/health", "/ready"}


class ObservabilityMiddleware:
    def __init__(self, app: ASGIApp, metrics: Metrics) -> None:
        self.app = app
        self.metrics = metrics

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = dict(scope["headers"])
        supplied = headers.get(b"x-request-id", b"").decode("latin-1")
        request_id = supplied if _VALID_REQUEST_ID.match(supplied) else uuid.uuid4().hex
        token = request_id_var.set(request_id)

        method = scope["method"]
        status = 500
        response_started = False
        started = time.perf_counter()
        self.metrics.http_in_progress.labels(method).inc()

        async def send_wrapper(message: Message) -> None:
            nonlocal status, response_started
            if message["type"] == "http.response.start":
                response_started = True
                status = message["status"]
                MutableHeaders(scope=message)["X-Request-ID"] = request_id
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except Exception:
            logger.exception("unhandled exception", extra={"method": method, "path": scope["path"]})
            if not response_started:
                response = error_response(500, "internal_error", "Internal server error")
                response.headers["X-Request-ID"] = request_id
                status = 500
                await response(scope, receive, send)
        finally:
            duration = time.perf_counter() - started
            route = scope.get("route")
            # Route template, or a fixed label for unmatched paths: bounded cardinality.
            path_label = getattr(route, "path", None) or "unmatched"
            self.metrics.http_in_progress.labels(method).dec()
            self.metrics.http_requests.labels(method, path_label, str(status)).inc()
            self.metrics.http_duration.labels(method, path_label).observe(duration)
            level = logging.DEBUG if scope["path"] in _QUIET_PATHS else logging.INFO
            # Query strings are deliberately not logged.
            logger.log(
                level,
                "request completed",
                extra={
                    "method": method,
                    "path": scope["path"],
                    "route": path_label,
                    "status": status,
                    "duration_ms": round(duration * 1000, 2),
                    "client": scope["client"][0] if scope.get("client") else None,
                },
            )
            request_id_var.reset(token)
