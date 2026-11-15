# Frontend and Nginx

React 19 + TypeScript + Vite 8, tested with Vitest 5 and Testing Library, served by
nginx (`nginxinc/nginx-unprivileged`). All versions are pinned exactly in
`frontend/package.json` and `package-lock.json`; the Docker build uses `npm ci`,
so it is reproducible. Source: `frontend/`.

## Features

- **Dashboard:** total, pending (`todo`), in-progress and completed (`done`) counters. The
  numbers are the `total` returned by the API for each status (`?status=…&limit=1`), so they
  stay exact regardless of how many tasks are loaded.
- **Create / edit / delete:** modal forms with client-side validation (title 1–200 characters
  after trimming, description ≤ 5000) mirroring the backend rules; server-side 422 details are
  shown in the dialog. Delete asks for confirmation.
- **Status management:** a status selector on every task (sends `PATCH {status}`).
- **Search and filter:** a status filter and a case-insensitive search over title and
  description. The API has no search parameter, so these run in the browser over the loaded
  tasks (up to 1000, paged 100 at a time). If there are more, a banner says so.
- **API health indicator:** *API healthy*, *Database unavailable* or *API unreachable*,
  re-checked every 15 s. The backend's `/health` and `/ready` are intentionally not proxied, so
  the indicator probes a real endpoint, `GET /api/v1/tasks?limit=1`: 200 = healthy;
  503 `database_unavailable` = degraded; anything else (network error, proxy 502/503, 5xx) =
  unreachable.
- **Loading and error states:** loading and empty states, a load-error banner with Retry,
  dismissible action errors, and in-dialog errors. Error messages include the backend's
  `request_id` as a reference. Raw HTML from a failing proxy is never rendered.
- Responsive layout, light/dark via `prefers-color-scheme`, keyboard accessible (labels, roles,
  Escape closes dialogs).

No authentication, routing library, state library or UI kit is used.

## API contract used (nothing invented)

`GET/POST /api/v1/tasks`, `GET/PATCH/DELETE /api/v1/tasks/{id}`. The error envelope
`{"error":{code,message,request_id,details}}` is parsed; non-JSON or unexpected bodies become a
generic error. `PUT` is part of the backend API but the UI does not need it.

## Layout

```
frontend/
  src/api/client.ts        fetch wrapper, ApiError, listAllTasks, countTasks, probeApi
  src/hooks/               useTasks (data + mutations), useApiHealth (polling)
  src/components/          StatsCards, TaskToolbar, TaskItem, TaskFormDialog, ConfirmDialog, HealthIndicator
  src/lib/validate.ts      form validation, date formatting
  src/test/                setup + fakeApi (in-memory stand-in for the FastAPI contract)
  nginx/nginx.conf         production nginx configuration
  nginx/security-headers.conf
  Dockerfile               stages: deps, test, build, runtime
```

## Nginx

| Concern | Configuration |
|---|---|
| Static files | React build in `/usr/share/nginx/html`; `/assets/*` is content-hashed and cached for 1 year (`immutable`); `index.html` is `no-cache` |
| SPA fallback | Unknown paths without a file extension serve `index.html`; unknown files with an extension, and dotfiles, are 404 |
| API proxy | Only `/api/v1/*` → `backend:8000` over the `proxy` network. Any other `/api/*` is a JSON 404 from nginx. `/health`, `/ready`, `/metrics` and the OpenAPI docs are not proxied (those paths return the SPA page) |
| Methods | API: GET, POST, PUT, PATCH, DELETE only (OPTIONS → 403, TRACE → 405). Static: GET/HEAD only |
| Size limits | `client_max_body_size 64k` (a max-size task is ~20 KB), small header buffers, 10 s header/body timeouts |
| Proxy behaviour | `X-Request-ID` set from nginx's `$request_id` (same id appears in nginx and backend logs); `X-Forwarded-For` is *replaced* by the client address; no retries of writes; `Server` and `X-Powered-By` from the backend are hidden; API responses are `Cache-Control: no-store` |
| Backend down | nginx returns JSON `503 {"error":{"code":"upstream_unavailable",…}}`. The backend's own errors (422, 404, 503 `database_unavailable`) pass through unchanged. The backend name is resolved at request time (Docker DNS `127.0.0.11`), so nginx starts without the backend and follows IP changes |
| Security headers | CSP (`default-src 'self'`, no inline script/style, `frame-ancestors 'none'`), `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, `Permissions-Policy`, COOP, CORP; `server_tokens off`. No HSTS: the service is plain HTTP on localhost (add it behind TLS) |
| Logging | JSON access log on stdout with `request_id`, `method`, **`path` only**, `status`, timings. No query string and no `Referer` is ever logged. `error_log` is `warn` on stderr (see limitation in `security.md`) |
| Shutdown | `STOPSIGNAL SIGQUIT` / compose `stop_signal: SIGQUIT`: nginx drains in-flight requests; `worker_shutdown_timeout 20s`, `stop_grace_period 30s`. Verified: stops in under 1 s when idle, exit code 0 |
| Hardening | uid 101, read-only root filesystem, `/tmp` tmpfs, all capabilities dropped, `no-new-privileges`, 128 MB / 0.5 CPU |

## Host port

nginx publishes `127.0.0.1:${FRONTEND_HOST_PORT:-8088}` → container 8080 (approved default 8088:
**on the development machine 8080 and 3000 are already used by other projects**). Open
`http://127.0.0.1:8088`; set `FRONTEND_HOST_PORT` in `.env` to change it. Grafana uses 3001 for the same reason
(`GRAFANA_HOST_PORT`, see `grafana.md`).

## Build, test, run

```sh
# Unit tests + type-check, in the pinned Node image (no local Node needed)
docker build --target test -t monitoring-3tier/frontend-test frontend
docker run --rm monitoring-3tier/frontend-test sh -c "npm run test && npx tsc --noEmit && npm run build"

# Whole stack
docker compose up -d --build --wait
sh tests/e2e/check_phase4.sh

# Local development (needs Node 22): API proxied to http://localhost:8000
cd frontend && npm ci && npm run dev
```
