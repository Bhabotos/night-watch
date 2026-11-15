"""Health, readiness, metrics, error handling and logging."""

import json
import logging

import pytest
from fastapi import APIRouter
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.exc import OperationalError

from app.core.logging import JsonFormatter, RedactionFilter
from app.db.session import ensure_not_superuser
from tests.conftest import TEST_PASSWORD

URL = "/api/v1/tasks"


def log_lines(capsys) -> list[dict]:
    out = capsys.readouterr().out
    return [json.loads(line) for line in out.splitlines() if line.startswith("{")]


# ---- health / readiness ---------------------------------------------------------------------


def test_health_is_ok(client):
    assert client.get("/health").json() == {"status": "ok"}


def test_ready_ok_when_database_reachable(client):
    response = client.get("/ready")
    assert response.status_code == 200
    assert response.json() == {"status": "ready", "database": "ok"}


def test_ready_503_without_leaking_details(client, tmp_path):
    client.app.state.engine = create_engine(f"sqlite:///{tmp_path}/missing-dir/x.db")
    response = client.get("/ready")
    assert response.status_code == 503
    assert response.json() == {"status": "not_ready", "database": "unavailable"}
    assert "missing-dir" not in response.text


def test_health_stays_up_when_database_is_down(client, tmp_path):
    client.app.state.engine = create_engine(f"sqlite:///{tmp_path}/missing-dir/x.db")
    assert client.get("/health").status_code == 200


# ---- metrics --------------------------------------------------------------------------------


def metric_lines(client) -> str:
    response = client.get("/metrics")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/plain")
    return response.text


def test_http_metrics_use_route_templates(client):
    task = client.post(URL, json={"title": "m"}).json()
    client.get(f"{URL}/{task['id']}")
    client.get("/definitely/not/a/route")
    text = metric_lines(client)
    assert (
        'http_requests_total{method="GET",path="/api/v1/tasks/{task_id}",status="200"} 1.0' in text
    )
    assert 'http_requests_total{method="POST",path="/api/v1/tasks",status="201"} 1.0' in text
    assert 'path="unmatched",status="404"' in text
    assert f"/api/v1/tasks/{task['id']}" not in text  # no unbounded labels
    assert "definitely" not in text
    assert "http_request_duration_seconds_bucket" in text
    assert 'http_requests_in_progress{method="GET"}' in text


def test_business_and_db_metrics(client):
    a = client.post(URL, json={"title": "a"}).json()
    client.post(URL, json={"title": "b", "status": "done"})
    client.patch(f"{URL}/{a['id']}", json={"status": "in_progress"})
    client.get(URL)
    client.delete(f"{URL}/{a['id']}")
    text = metric_lines(client)
    assert 'tasks_operations_total{operation="create"} 2.0' in text
    assert 'tasks_operations_total{operation="update"} 1.0' in text
    assert 'tasks_operations_total{operation="list"} 1.0' in text
    assert 'tasks_operations_total{operation="delete"} 1.0' in text
    assert 'tasks_count{status="done"} 1.0' in text
    assert 'tasks_count{status="todo"} 0.0' in text
    assert 'db_query_duration_seconds_count{operation="insert"}' in text
    assert "db_pool_connections" in text


def test_failed_operations_are_not_counted_as_successes(client):
    client.get(f"{URL}/99999")
    assert 'tasks_operations_total{operation="read"} 0.0' in metric_lines(client)


def test_metrics_contain_no_secrets_or_connection_details(client, settings):
    client.post(URL, json={"title": "hello-world-title", "description": "private-description"})
    text = metric_lines(client)
    for forbidden in (
        TEST_PASSWORD,
        settings.db_user,
        settings.db_host,
        "hello-world-title",
        "private-description",
    ):
        assert forbidden not in text


def test_task_count_metric_absent_when_database_fails(client, tmp_path):
    from app.core.metrics import TaskCountCollector

    broken = create_engine(f"sqlite:///{tmp_path}/missing-dir/x.db")
    assert list(TaskCountCollector(broken).collect()) == []


# ---- error handling -------------------------------------------------------------------------


@pytest.fixture
def failing_client(capsys, settings, sqlite_engine):
    from app.main import create_app

    app = create_app(settings, sqlite_engine)
    router = APIRouter()

    @router.get("/boom")
    def boom():
        raise RuntimeError(f"internal detail {TEST_PASSWORD}")

    @router.get("/db-down")
    def db_down():
        raise OperationalError("SELECT 1", {}, Exception(f"host={settings.db_host}"))

    app.include_router(router)
    with TestClient(app, raise_server_exceptions=False) as test_client:
        yield test_client


def test_unhandled_exception_returns_generic_500(failing_client, capsys):
    response = failing_client.get("/boom")
    assert response.status_code == 500
    body = response.json()["error"]
    assert body["code"] == "internal_error"
    assert body["message"] == "Internal server error"
    assert body["request_id"] == response.headers["x-request-id"]
    assert "internal detail" not in response.text
    entries = log_lines(capsys)
    failure = next(e for e in entries if e["message"] == "unhandled exception")
    assert "RuntimeError" in failure["exception"]
    assert TEST_PASSWORD not in json.dumps(entries)  # redacted from the traceback


def test_500_is_counted_in_metrics(failing_client):
    failing_client.get("/boom")
    assert 'path="/boom",status="500"} 1.0' in failing_client.get("/metrics").text


def test_database_errors_map_to_503(failing_client):
    response = failing_client.get("/db-down")
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "database_unavailable"
    assert "db.invalid" not in response.text


def test_method_not_allowed_uses_error_shape(client):
    response = client.delete(URL)
    assert response.status_code == 405
    assert response.json()["error"]["code"] == "method_not_allowed"


# ---- logging --------------------------------------------------------------------------------


def test_access_log_is_json_with_request_fields(client, capsys):
    capsys.readouterr()
    response = client.post(URL, json={"title": "x"}, headers={"X-Request-ID": "abc-123"})
    assert response.headers["x-request-id"] == "abc-123"
    entry = next(e for e in log_lines(capsys) if e["message"] == "request completed")
    assert entry["request_id"] == "abc-123"
    assert entry["method"] == "POST"
    assert entry["route"] == "/api/v1/tasks"
    assert entry["status"] == 201
    assert entry["duration_ms"] >= 0
    assert entry["level"] == "INFO"
    assert "timestamp" in entry


def test_invalid_request_id_is_replaced(client):
    response = client.get("/health", headers={"X-Request-ID": "bad id\twith spaces"})
    request_id = response.headers["x-request-id"]
    assert request_id != "bad id\twith spaces"
    assert len(request_id) == 32


def test_query_string_is_not_logged(client, capsys):
    capsys.readouterr()
    client.get(URL, params={"status": "todo", "token": "super-secret-token"})
    app_logs = [e for e in log_lines(capsys) if e["logger"].startswith("app")]
    assert app_logs  # the request was logged...
    assert "super-secret-token" not in json.dumps(app_logs)  # ...without its query string


def test_health_checks_are_quiet_at_info_level(client, capsys):
    capsys.readouterr()
    client.get("/health")
    client.get("/metrics")
    assert [e for e in log_lines(capsys) if e["message"] == "request completed"] == []


def test_json_formatter_includes_extras_and_exceptions():
    record = logging.LogRecord("x", logging.ERROR, "f", 1, "msg %s", ("a",), None)
    record.custom_field = 7
    try:
        raise ValueError("bad")
    except ValueError:
        import sys

        record.exc_info = sys.exc_info()
    data = json.loads(JsonFormatter().format(record))
    assert data["message"] == "msg a"
    assert data["custom_field"] == 7
    assert "ValueError" in data["exception"]


def test_redaction_filter_masks_secret_in_message_and_args():
    record = logging.LogRecord("x", logging.INFO, "f", 1, "connect with %s", ("hunter2",), None)
    RedactionFilter(["hunter2"]).filter(record)
    assert "hunter2" not in record.getMessage()
    assert "***" in record.getMessage()


# ---- startup safety -------------------------------------------------------------------------


class _FakeResult:
    def __init__(self, value):
        self.value = value

    def scalar_one_or_none(self):
        return self.value


class _FakeConn:
    def __init__(self, value):
        self.value = value

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def execute(self, *_):
        return _FakeResult(self.value)


class _FakeEngine:
    def __init__(self, value):
        self.value = value

    def connect(self):
        return _FakeConn(self.value)


def test_superuser_role_is_refused():
    with pytest.raises(RuntimeError, match="superuser"):
        ensure_not_superuser(_FakeEngine(True))


def test_non_superuser_role_is_accepted():
    ensure_not_superuser(_FakeEngine(False))
