"""Structured JSON logging with request-id correlation and secret redaction."""

import contextvars
import json
import logging
import sys
from datetime import UTC, datetime

request_id_var: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "request_id", default=None
)

# Attributes present on every LogRecord; anything else came from `extra=`.
_RESERVED = set(logging.LogRecord("", 0, "", 0, "", (), None).__dict__) | {
    "message",
    "asctime",
    "color_message",
}
_REDACTED = "***"


class RedactionFilter(logging.Filter):
    """Replaces known secret values anywhere in a log message or traceback."""

    def __init__(self, secrets: list[str]) -> None:
        super().__init__()
        self._secrets = [s for s in secrets if s]

    def redact(self, text: str) -> str:
        for secret in self._secrets:
            text = text.replace(secret, _REDACTED)
        return text

    def filter(self, record: logging.LogRecord) -> bool:
        if self._secrets:
            record.msg = self.redact(record.getMessage())
            record.args = None
            if record.exc_info:
                record.exc_text = self.redact(logging.Formatter().formatException(record.exc_info))
                record.exc_info = None
        return True


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, object] = {
            "timestamp": datetime.fromtimestamp(record.created, UTC).isoformat(
                timespec="milliseconds"
            ),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        request_id = request_id_var.get()
        if request_id:
            payload["request_id"] = request_id
        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value
        if record.exc_text:
            payload["exception"] = record.exc_text
        elif record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload, default=str)


class StdoutHandler(logging.StreamHandler):
    """Writes to whatever sys.stdout is at emit time (container stdout in production)."""

    def __init__(self) -> None:
        super().__init__()

    @property
    def stream(self):  # type: ignore[override]
        return sys.stdout

    @stream.setter
    def stream(self, value) -> None:
        pass


def setup_logging(level: str = "INFO", secrets: list[str] | None = None) -> None:
    handler = StdoutHandler()
    handler.setFormatter(JsonFormatter())
    handler.addFilter(RedactionFilter(secrets or []))

    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(level.upper())

    # Route uvicorn's own loggers through the same JSON handler. Access logging is
    # done by our middleware (it adds request_id, duration and route-level detail).
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        logger = logging.getLogger(name)
        logger.handlers.clear()
        logger.propagate = True
    logging.getLogger("uvicorn.access").disabled = True
