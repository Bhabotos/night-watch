"""Prometheus metrics.

Everything lives on a per-application CollectorRegistry (no global state), so
tests can create many apps. Label values are bounded: HTTP paths are route
templates (/api/v1/tasks/{task_id}), never raw URLs, and no label carries user
data, identifiers, credentials or connection details.
"""

import logging
import re
import time
from collections.abc import Iterable

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram
from prometheus_client.core import GaugeMetricFamily
from prometheus_client.metrics_core import Metric
from prometheus_client.registry import Collector
from sqlalchemy import Engine, event, text

from app.db.models import TaskStatus

logger = logging.getLogger(__name__)

HTTP_BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)
DB_BUCKETS = (0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 5.0)
TASK_OPERATIONS = ("create", "read", "list", "replace", "update", "delete")
_VERB = re.compile(r"\s*(\w+)")


class Metrics:
    def __init__(self, registry: CollectorRegistry) -> None:
        self.registry = registry
        self.http_requests = Counter(
            "http_requests_total",
            "HTTP requests handled.",
            ["method", "path", "status"],
            registry=registry,
        )
        self.http_duration = Histogram(
            "http_request_duration_seconds",
            "HTTP request latency.",
            ["method", "path"],
            buckets=HTTP_BUCKETS,
            registry=registry,
        )
        self.http_in_progress = Gauge(
            "http_requests_in_progress",
            "HTTP requests currently being handled.",
            ["method"],
            registry=registry,
        )
        self.task_operations = Counter(
            "tasks_operations_total",
            "Task operations performed, by operation.",
            ["operation"],
            registry=registry,
        )
        self.db_query_duration = Histogram(
            "db_query_duration_seconds",
            "Database statement latency.",
            ["operation"],
            buckets=DB_BUCKETS,
            registry=registry,
        )
        # Pre-create series so rate() and alerts work before the first event.
        for operation in TASK_OPERATIONS:
            self.task_operations.labels(operation)

    def instrument_engine(self, engine: Engine) -> None:
        """Time every statement and expose connection-pool state and task counts."""

        @event.listens_for(engine, "before_cursor_execute")
        def _start(conn, cursor, statement, parameters, context, executemany):
            conn.info.setdefault("query_start", []).append(time.perf_counter())

        @event.listens_for(engine, "after_cursor_execute")
        def _stop(conn, cursor, statement, parameters, context, executemany):
            started = conn.info["query_start"].pop()
            match = _VERB.match(statement)
            verb = match.group(1).lower() if match else "other"
            if verb not in {"select", "insert", "update", "delete"}:
                verb = "other"
            self.db_query_duration.labels(verb).observe(time.perf_counter() - started)

        self.registry.register(PoolCollector(engine))
        self.registry.register(TaskCountCollector(engine))


class PoolCollector(Collector):
    def __init__(self, engine: Engine) -> None:
        self._pool = engine.pool

    def collect(self) -> Iterable[Metric]:
        gauge = GaugeMetricFamily(
            "db_pool_connections",
            "SQLAlchemy connection pool connections, by state.",
            labels=["state"],
        )
        pool = self._pool
        if hasattr(pool, "checkedout"):
            gauge.add_metric(["checked_out"], pool.checkedout())
            gauge.add_metric(["checked_in"], pool.checkedin())
            gauge.add_metric(["overflow"], max(pool.overflow(), 0))
        yield gauge


class TaskCountCollector(Collector):
    """Current number of tasks per status, read from the database at scrape time.

    If the database is unreachable the metric is omitted (not zeroed), so alerts
    on absence work and a DB outage never fails the whole scrape.
    """

    def __init__(self, engine: Engine) -> None:
        self._engine = engine

    def collect(self) -> Iterable[Metric]:
        try:
            with self._engine.connect() as conn:
                rows = conn.execute(text("SELECT status, count(*) FROM tasks GROUP BY status"))
                counts = {status: int(count) for status, count in rows}
        except Exception as exc:
            logger.warning("task count collection failed", extra={"error_type": type(exc).__name__})
            return
        gauge = GaugeMetricFamily("tasks_count", "Current tasks, by status.", labels=["status"])
        for status in TaskStatus:
            gauge.add_metric([status.value], counts.get(status.value, 0))
        yield gauge
