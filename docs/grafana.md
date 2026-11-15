# Grafana: dashboards

`grafana/grafana:13.3.1` (pinned). Open **http://127.0.0.1:3001** and sign in with
`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env` (no default password; there is no
anonymous access and no sign-up). The home page is the Application dashboard.

| | |
|---|---|
| Networks | `edge` (published port, future alert-webhook egress) and `monitoring` (Prometheus) |
| Published | `127.0.0.1:${GRAFANA_HOST_PORT:-3001}` -> 3000. Port 3000 is used by other projects on the development machine |
| Storage | Named volume `monitoring-3tier_grafana_data` (`/var/lib/grafana`, SQLite): users, stars, preferences, folders |
| Hardening | uid 472, read-only root filesystem (`/tmp` tmpfs), all capabilities dropped, `no-new-privileges`, 512 MB / 0.5 CPU |
| Config | Environment variables only (`GF_*` in `docker-compose.yml`); secrets from `.env` |

## Provisioning (everything is code)

| File | Effect |
|---|---|
| `monitoring/grafana/provisioning/datasources/prometheus.yml` | Datasource `Prometheus` (uid `prometheus`, `http://prometheus:9090`, default, **read-only**) |
| `monitoring/grafana/provisioning/datasources/loki.yml` | Datasource `Loki` (uid `loki`, `http://loki:3100`, **read-only**, `request_id` derived field), added in Phase 7 |
| `monitoring/grafana/provisioning/dashboards/dashboards.yml` | Loads `monitoring/grafana/dashboards/*.json` into the folder *Monitoring*; `disableDeletion: true`, `allowUiUpdates: false` |
| `monitoring/grafana/dashboards/*.json` | The four dashboards below |

All three mounts are read-only. The provisioned datasource and dashboards cannot be modified or
deleted through the UI or the API (verified by `check_phase6.sh`). To change a dashboard, edit its
JSON in the repository; Grafana reloads it within 30 seconds. Dashboards are queried by datasource
**uid**, never by name.

## Dashboards

**Host (Docker VM)** (`host-vm`): CPU, memory, load, uptime, OOM kills, disk.
- Disk panels are titled **"Docker data disk ..."**. They show the usage of the disk that stores
  Docker images, containers and volumes (the containers' root overlay). Windows drives (`C:`, `D:`)
  are **not** monitored, and the dashboard says so in a note panel.
- Disk I/O panels are titled "VM block devices ..." because the kernel counters cover every block
  device in the VM, not only the data disk.
- There are no network panels: node-exporter runs in its own network namespace, so
  `node_network_*` would describe only its own container. A lint rule forbids adding them.
- CPU uses the non-idle formulation (see `prometheus.md`); the Docker Desktop idle counters
  under-tick.

**Application (Tasks API)** (`app-tasks`): backend up, request rate, 5xx ratio, p95 latency,
in-flight requests, task count; traffic by status and route; p50/p95/p99 and p95 by route; 4xx/5xx;
database latency, query rate and connection pool; tasks by status and operations; backend memory and
CPU. Health checks and scrapes are excluded from the per-route panels.

**PostgreSQL** (`postgres`): up, connections used, size, cache hit ratio, transactions/s,
deadlocks; connections by state against `max_connections`; commits/rollbacks; rows per second;
block hits vs reads; temp files; locks; background writer; database size and `tasks` table live/dead
rows and scans. Queries are scoped to the `tasks` database. There are no `pg_stat_statements`
panels: the exporter does not collect them.

**Logs (Loki)** (`logs`, Phase 7): log volume by service and level, nginx requests by severity and
p95 request time, log panels for errors, warnings, backend requests, nginx access and error logs,
PostgreSQL and everything, plus pipeline health (lines shipped, received, dropped, active streams). It
has Service, Level and Search (regex) variables; click `request_id` in a log line and then *Whole request*
to see the request in nginx and the backend. See `loki.md`.

The dashboards use the Phase 5 recording rules where they exist. Alert rules arrive in Phase 8.

## Tests

```sh
python -I tests/e2e/dashboards_lint.py        # static: units, titles, uids, labels, no secrets, no overlaps
sh tests/e2e/check_phase6.sh                  # service, auth, provisioning, hardening, persistence (77 checks)
FULL_CYCLE=1 sh tests/e2e/check_phase6.sh     # + docker compose down/up (no -v) and data survival
PERSISTENCE=0 sh tests/e2e/check_phase6.sh    # skip all restart tests
```

`tests/e2e/grafana_panels_check.py` runs **every query of every dashboard through Grafana** against
Prometheus and fails on an error *or* on an empty result (Grafana returns an empty frame for a
metric that does not exist, so frame counting is not enough; this was verified with a negative test).
The lint and the panel check were both mutation-tested to confirm they fail on bad input.

Restart persistence covered: Grafana restart, Grafana container re-creation (a folder and a star
created through the API survive), Prometheus restart (history kept), and a full
`docker compose down` + `up` **without `-v`** (PostgreSQL data, Prometheus history and Grafana state
survive; all volumes untouched).

## Security notes

See `security.md`. In short: login is required; the admin password is an environment variable;
Grafana's own `/metrics` is disabled; the anonymous version leak is masked; Grafana can reach
Prometheus and nothing else on the data side; nginx and Grafana share `edge` and can reach each
other; Grafana keeps internet egress for the alert webhooks of Phase 8.
