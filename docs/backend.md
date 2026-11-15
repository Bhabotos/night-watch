# Backend (FastAPI)

Python 3.12, FastAPI, SQLAlchemy 2.x (psycopg 3), Alembic, Pydantic v2,
prometheus-client. Source: `backend/`. Dependencies are pinned in
`backend/requirements.txt` (runtime) and `backend/requirements-dev.txt`.

## Layout

```
backend/
  app/
    main.py              create_app(): wiring, lifespan, middleware, routers
    config.py            Settings from environment (DB_* have no defaults)
    api/                 routes_tasks.py, routes_health.py (/health /ready /metrics)
    core/                logging.py, metrics.py, middleware.py, errors.py
    db/                  base.py, models.py, session.py
    schemas/task.py      Pydantic request/response models
    services/tasks.py    persistence logic (owns transactions)
  alembic/               env.py, versions/0001_create_tasks.py
  tests/                 unit/ (SQLite, no DB service), integration/ (PostgreSQL)
  Dockerfile             targets: builder, test, runtime (non-root)
```

## Endpoints

Everything under `/api/*` is what nginx will proxy (Phase 4). `/health`,
`/ready` and `/metrics` are **not** under `/api` so nginx does not expose them;
Docker health checks and Prometheus reach them on the `metrics`/`proxy` networks.

| Method | Path | Success | Notes |
|---|---|---|---|
| POST | `/api/v1/tasks` | 201 | Body: `title` (1-200, trimmed), `description` (<=5000, optional), `status` (default `todo`) |
| GET | `/api/v1/tasks` | 200 | Query: `status`, `limit` (default 20, capped at `MAX_PAGE_SIZE`=100), `offset`. Returns `{items,total,limit,offset}`, newest first |
| GET | `/api/v1/tasks/{id}` | 200 | 404 `task_not_found` |
| PUT | `/api/v1/tasks/{id}` | 200 | Full replacement; omitted optional fields reset |
| PATCH | `/api/v1/tasks/{id}` | 200 | Partial; at least one field; `title`/`status` cannot be null; `description: null` clears it |
| DELETE | `/api/v1/tasks/{id}` | 204 | 404 if missing |
| GET | `/health` | 200 | Liveness. Never touches the database |
| GET | `/ready` | 200 / 503 | Readiness: `SELECT 1`. Body never includes error detail |
| GET | `/metrics` | 200 | Prometheus text format |

Task statuses: `todo`, `in_progress`, `done` (enforced by a database CHECK).

Errors always use one shape: `{"error": {"code", "message", "request_id", ["details"]}}`.

| Status | code | When |
|---|---|---|
| 404 | `task_not_found`, `not_found` | Missing task / unknown route |
| 405 | `method_not_allowed` | |
| 422 | `validation_error` | `details` has field, message, type. The submitted value is **not** echoed |
| 503 | `database_unavailable` | Connection failure, statement timeout, pool exhausted |
| 500 | `internal_error` | Anything unhandled; generic message, traceback only in logs |

Every response carries `X-Request-ID` (a valid inbound one, `[A-Za-z0-9._-]{1,64}`,
is reused; otherwise one is generated).

## Configuration (environment)

| Variable | Default | Purpose |
|---|---|---|
| `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` | none (required) | Compose maps these from `APP_DB_*`; the backend never receives the admin credentials |
| `DB_PORT` | 5432 | |
| `DB_POOL_SIZE` / `DB_MAX_OVERFLOW` | 5 / 5 | |
| `DB_POOL_TIMEOUT_S` / `DB_CONNECT_TIMEOUT_S` | 5 / 5 | |
| `DB_STATEMENT_TIMEOUT_MS` | 5000 | Server-side `statement_timeout` |
| `MAX_PAGE_SIZE` | 100 | |
| `LOG_LEVEL` | INFO | Compose: `BACKEND_LOG_LEVEL` |

At startup the app refuses to run if its database role is a superuser.

## Metrics

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `http_requests_total` | counter | method, path, status | `path` is the route template (`/api/v1/tasks/{task_id}`); unknown URLs are `unmatched` |
| `http_request_duration_seconds` | histogram | method, path | Latency |
| `http_requests_in_progress` | gauge | method | In-flight requests |
| `tasks_operations_total` | counter | operation | create, read, list, replace, update, delete. Counted only on success |
| `tasks_count` | gauge | status | Tasks per status, read from the DB at scrape time. **Absent** (not zero) if the DB is unreachable |
| `db_query_duration_seconds` | histogram | operation | select, insert, update, delete, other |
| `db_pool_connections` | gauge | state | checked_out, checked_in, overflow |
| `process_*`, `python_gc_*`, `python_info` | standard | | Process and runtime metrics |

No label contains user data, task content, ids, credentials or connection
details; cardinality is bounded.

## Logging

One JSON object per line on stdout. Fields: `timestamp` (UTC, ms), `level`,
`logger`, `message`, `request_id` (when in a request) plus structured extras.
Request logs (`logger=app.access`, message `request completed`): `method`,
`path`, `route`, `status`, `duration_ms`, `client`. Query strings are never
logged. `/health`, `/ready` and `/metrics` log at DEBUG. Unhandled errors log
`unhandled exception` with a traceback. The configured DB password is
replaced with `***` anywhere it appears in a message or traceback.

## Migrations

`alembic upgrade head` runs automatically when the container starts, using the
application role. Revision `0001` creates `tasks` (identity PK, CHECK on
status, indexes on `status` and `created_at`).

```sh
docker compose exec backend alembic current
docker compose exec backend alembic history
docker compose exec backend alembic upgrade head
```

New migrations are written by hand (or autogenerated and reviewed); an
integration test fails if models and migrations drift apart.

## Tests and linting

PostgreSQL is not published to the host, so the full suite runs on the
`application` network inside the `backend-test` service:

```sh
docker compose --profile test run --rm --build backend-test     # ruff check, ruff format --check, pytest -v
docker compose --profile test run --rm backend-test pytest -v --cov=app --cov-report=term-missing
```

- `tests/unit` use in-memory SQLite and need no database.
- `tests/integration` run migrations (upgrade, downgrade, re-upgrade, drift
  check), CRUD, readiness, metrics and DB-outage behaviour against PostgreSQL,
  each inside a throw-away schema that is dropped afterwards. They never touch
  `public.tasks`.
