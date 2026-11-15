# 3-Tier Application Monitoring Platform

Tasks application (React + FastAPI + PostgreSQL) with Prometheus, Loki, Alloy
and Grafana for metrics, logs, dashboards and alerting.

**Status:** Phase 7 (Loki, Alloy and the Logs dashboard) implemented and awaiting approval.
All ten services run: PostgreSQL, backend, nginx, Prometheus, node-exporter, postgres-exporter,
Grafana, Loki, Alloy and the Docker socket proxy. Alerting comes next (Phase 8).

## Network design (summary)

Six Docker networks: `edge` (external connectivity: nginx, Grafana), `uiaccess` (non-internal, contains
only the Prometheus UI forwarder) and `proxy`, `application`, `metrics`, `monitoring` (all `internal: true`).
nginx and PostgreSQL share no network; nginx reaches the backend via `proxy`. Only nginx
(`127.0.0.1:8088`), Grafana (`127.0.0.1:3001`) and the Prometheus UI forwarder (`127.0.0.1:9090`) publish
ports; PostgreSQL, Prometheus itself, Loki, Alloy and the exporters are never published. These are
segmentation controls, **not** directional firewalls. Details and limits:
[docs/architecture.md](docs/architecture.md).

## Quick start (Phases 2-7)

```sh
cp .env.example .env        # then replace every CHANGE_ME with a strong secret
docker compose config -q    # validate
docker compose up -d --build --wait  # PostgreSQL, backend (migrations), nginx/UI, Prometheus, exporters
sh tests/e2e/check_phase2.sh
sh tests/e2e/check_network_design.sh
sh tests/e2e/check_phase4.sh        # UI, proxy, headers, network isolation
sh tests/e2e/check_phase5.sh        # Prometheus, exporters, rules, isolation
sh tests/e2e/check_phase6.sh        # Grafana, dashboards, security, restart persistence
sh tests/e2e/check_phase7.sh        # Loki, Alloy, socket proxy, log collection, Logs dashboard
docker compose --profile test run --rm --build backend-test  # ruff + pytest
docker compose down         # stop (keeps data); add -v ONLY to delete the database
```

Open the UI at `http://127.0.0.1:8088`, the Prometheus UI at `http://127.0.0.1:9090` and the dashboards at
`http://127.0.0.1:3001`
(sign in with `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`). Port 8080 is used by another project on the
development machine; to change the port set `FRONTEND_HOST_PORT` in `.env`.

## Documentation

- Architecture, networks and flows: [docs/architecture.md](docs/architecture.md)
- Backend API, metrics, logging, tests: [docs/backend.md](docs/backend.md)
- Frontend and nginx: [docs/frontend.md](docs/frontend.md)
- Prometheus and exporters: [docs/prometheus.md](docs/prometheus.md)
- Grafana and dashboards: [docs/grafana.md](docs/grafana.md)
- Logs (Loki, Alloy, Docker socket proxy): [docs/loki.md](docs/loki.md)
- Security notes (Docker socket, egress, Docker Desktop):
  [docs/security.md](docs/security.md)
- Decision log: [docs/decisions.md](docs/decisions.md)

## Roadmap

| Phase | Title |
|---|---|
| 1 | Project Architecture and Repository Structure |
| 2 | Scaffolding, `.env.example`, Compose Skeleton, PostgreSQL |
| 3 | FastAPI Backend (CRUD, Health, Metrics, Logging, Tests) |
| 4 | React Frontend and Nginx |
| 5 | Prometheus and Exporters |
| 6 | Grafana Provisioning and Dashboards |
| 7 | Loki and Alloy |
| 8 | Grafana Alerting |
| 9 | Hardening and Resource Limits |
| 10 | End-to-End Smoke Tests, Final Documentation and Full-Stack Validation |
