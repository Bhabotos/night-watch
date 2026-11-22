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

---

# Night Watch: monitoring and alerting (Module 6)

This repository's observability stack also answers the Module 6 "Night Watch" assignment. Plan and status:
[NIGHT_WATCH_PLAN.md](NIGHT_WATCH_PLAN.md), [NIGHT_WATCH_TASK_TRACKER.md](NIGHT_WATCH_TASK_TRACKER.md); evidence (real command output and results):
[docs/NIGHT_WATCH_EVIDENCE.md](docs/NIGHT_WATCH_EVIDENCE.md).

| Task | Where |
|---|---|
| Prometheus (host, backend API, database, frontend probe) | `monitoring/prometheus/prometheus.yml`, `monitoring/blackbox/blackbox.yml` |
| Grafana and data source | `monitoring/grafana/provisioning/` |
| Community dashboard | `monitoring/grafana/dashboards/night-watch/node-exporter-full-1860.json` |
| Dashboard "Three-Tier App – Production" | `monitoring/grafana/dashboards/night-watch/three-tier-production.json` |
| Alert rules, routing and notifications | `monitoring/prometheus/rules/alerts.yml`, `monitoring/alertmanager/alertmanager.yml`, `monitoring/alert-sink/` |
| Alert rule tests and the controlled failure demo | `tests/prometheus/alerts_test.yml`, `tests/e2e/alert_demo.sh` |
| CI/CD (validation on every PR, deploy on push to `main`) | `.github/workflows/`, `scripts/validate_monitoring.sh`, `tests/ci/`, [docs/NIGHT_WATCH_DEPLOYMENT.md](docs/NIGHT_WATCH_DEPLOYMENT.md) |

## Monitoring architecture and alerting flow

```
 user -> nginx (frontend, 127.0.0.1:8088) -> FastAPI backend -> PostgreSQL

 Blackbox Exporter --HTTP probe--> nginx            (frontend availability: probe_success)
 Prometheus --scrape every 15 s--> backend /metrics, node-exporter, postgres-exporter, blackbox, alertmanager, loki, alloy
 Prometheus: recording rules (recording.yml) + 9 alert rules (alerts.yml) evaluated every 15 s
 Prometheus --firing alerts--> Alertmanager --group_by [alertname, tier], group_wait 30 s--> receiver "local-webhook" (alert-sink, logs JSON)
 Grafana --PromQL--> Prometheus   (Node Exporter Full, Three-Tier App - Production)
```
Alert rules cover the four areas: tier down (`FrontendDown`, `BackendDown`, `PostgresDown`, each `for: 1m`), API errors and latency (`BackendHighErrorRate`,
`BackendHighLatencyP95`), database connections (`PostgresHighConnections`) and server resources (`HostHighCpu`, `HostHighMemory`, `HostDiskAlmostFull`).
Prometheus is the **pull** side; Alertmanager groups, deduplicates and routes; the receiver is a local webhook (Telegram is defined but unconfigured). Nothing is published
beyond `127.0.0.1`. More detail: [docs/architecture.md](docs/architecture.md), [docs/NIGHT_WATCH_EVIDENCE.md](docs/NIGHT_WATCH_EVIDENCE.md).

## Evidence (screenshots in `evidence/screenshots/`)

| File | Shows |
|---|---|
| `01-grafana-dashboards-list.png` | The 6 dashboards in folder *Monitoring* |
| `02-node-exporter-full-1860.png` | Community dashboard, job `node` |
| `03-three-tier-app-production.png` | Production dashboard, all four rows, with traffic |
| `04-prometheus-targets.png`, `05-prometheus-alerts-inactive.png` | Targets UP; all alert rules inactive |
| `06-docker-compose-ps.png`, `07-alert-sink-firing-resolved.png` | Rendered from captured command output (not live terminal windows); `.txt` originals alongside |
| `08-grafana-frontend-availability-DOWN.png` | Controlled failure 2026-11-22 04:31 UTC: Frontend availability DOWN |
| `09-prometheus-FrontendDown-FIRING.png` | Prometheus `/alerts`: `FrontendDown` FIRING (04:32 UTC) |
| `10-prometheus-FrontendDown-after-recovery.png`, `11-grafana-frontend-availability-recovered.png` | After recovery: alert gone, panel UP |
| `12-github-actions-green-run-pr1.png` | GitHub Actions: Monitoring validation green on PR #1 |
| `13-github-actions-red-run-pr2-expected-failure.png` | Deliberate failure (invalid PromQL in `BackendDown`), PR #2 |
| `14-github-actions-green-after-fix-pr2.png` | Green again after the fix |
| `15-prometheus-targets-all-9-up.png` | Full-height Targets page: all 9 targets UP, postgres included (`04` is kept as the original) |
| `16-promql-1-backend-request-rate.png`, `17-promql-2-server-cpu-utilisation.png`, `18-promql-3-database-connection-ratio.png` | The three PromQL queries with their results (backend request rate, server CPU, database connection ratio); each has a `.txt` description |
| `19-grafana-prometheus-datasource-test-success.png` | Provisioned Prometheus datasource: Test shows "Successfully queried the Prometheus API." |
| `20-github-actions-deploy-run-waiting-approval.png` | Deploy run 44986551856: push to `main`, validation passed, deploy job waiting for `production` approval (not approved) |

CI: repository https://github.com/Bhabotos/night-watch, [PR #1](https://github.com/Bhabotos/night-watch/pull/1) (green run 44986089290; **merged** as `7145b54`), [PR #2](https://github.com/Bhabotos/night-watch/pull/2) (negative test, still open: red run 44986168079, green again 44986230651). The merge started the deploy workflow ([run 44986551856](https://github.com/Bhabotos/night-watch/actions/runs/44986551856)): validation passed and the *Deploy to Hetzner VPS* job is **waiting for approval** in the `production` environment (required reviewer, branch `main`, no secrets); no deployment has been performed; details in [docs/NIGHT_WATCH_EVIDENCE.md](docs/NIGHT_WATCH_EVIDENCE.md). Deployment to the VPS is prepared but not executed.

The matching raw timeline is `evidence/alert_demo_2026-11-22T0430Z.txt` (firing, webhook delivery, recovery, resolved). Times are UTC; Bangladesh time is UTC+6 (04:31 UTC = 10:31).

## Community dashboard: Node Exporter Full (Grafana.com ID 1860)

It was chosen because the server-health requirement (CPU, memory, disk, network, load) is exactly what Node Exporter exposes, and this dashboard is the
most widely used and maintained community dashboard for it (revision 46 was imported unmodified). It saves rebuilding hundreds of standard host panels and
gives a deeper drill-down (per-core CPU, memory breakdown, disk I/O, network errors) than the summary gauges of our own dashboard. In this environment
Node Exporter runs in a Docker Desktop VM, so the panels describe that VM; panels for collectors it does not provide (systemd, hardware sensors, TCP state)
are empty by design, and the CPU, memory, disk, network and load panels all show data.

## Answers to the four questions

### 1. Push or pull metrics, and which does Prometheus use?

In a **push** model each monitored system sends its metrics to a central collector when it decides to. In a **pull** model the collector decides when to
fetch: it requests an HTTP endpoint from every target on a schedule. **Prometheus is pull-based**: every 15 seconds it scrapes `/metrics` from the
backend, Node Exporter, the PostgreSQL exporter and Blackbox Exporter (see `prometheus.yml`). Pulling gives a free health signal, because a target
that cannot be scraped has `up == 0`, and that is exactly how our `BackendDown` and `PostgresDown` alerts work. It also means the central server controls
the load, targets need no knowledge of where Prometheus is, and you can check a target by opening its URL in a browser. The trade-offs are that Prometheus
must be able to reach every target (here they share Docker networks) and that very short-lived jobs may finish between scrapes; for those Prometheus offers the
Pushgateway as a deliberate exception. Push models suit firewalled clients and batch jobs, but then a silent sender is hard to tell apart from a healthy idle one.

### 2. Monitoring versus observability

**Monitoring** watches signals we decided in advance were important (CPU, error rate, "is the frontend up") and tells us *that* something is wrong, usually
through dashboards and alerts. It answers known questions. **Observability** is a property of the system: whether its telemetry, meaning metrics, logs and
traces, is rich enough that we can work out *why* it misbehaves, including failures nobody predicted, without shipping new code first. In this project the
Prometheus alerts and the "Three-Tier App – Production" dashboard are monitoring, while having the same incident visible in metrics (error rate), logs
(Loki, collected by Alloy) and, if we add it, traces is what makes it investigable. Monitoring is a part of observability, not a substitute for it.

### 3. The website is slow: which dashboard panels, and in what order?

I would follow the request path from the user inwards, on the "Three-Tier App – Production" dashboard, and keep one time window for all panels so events can be correlated:

1. **Frontend:** *Frontend availability*, *Availability (selected range)* and *Frontend probe duration*. Is the page up, and is it slow at the front door?
2. **Backend API:** *Response time p95* and *Response time (p50 / p95)* to confirm the slowness and its size, then *Request rate* and *Request rate by status*
   (a traffic spike?), *Error rate (5xx)* and *Requests by route* (which endpoint?).
3. **Database:** *PostgreSQL health*, *Connection usage* and *Connections by state*. A saturated connection pool or many connections stuck "idle in transaction"
   makes the API slow while the API itself looks fine.
4. **Server:** *CPU usage*, *Memory usage*, *Disk usage* and *CPU / memory / disk over time*, to see whether the host is the bottleneck. If a number looks odd I would open
   the Node Exporter Full dashboard for detail.

I stop at the first tier whose panels went abnormal at the time the slowness began; only then is it worth reading that tier's logs in the Logs dashboard.

### 4. What is alert fatigue and how do we prevent it?

Alert fatigue is what happens when people receive so many alerts, many of them noisy, duplicated or not actionable, that they stop trusting and reading them,
so a real outage gets missed (which is the failure Night Watch is meant to prevent). Prevention used or planned in this project:

- **Alert on symptoms people care about** (tier down, error rate, saturation) rather than on every internal metric.
- **Sensible thresholds with a sustained `for:` duration**, so a one-minute blip does not page anyone: for example 5xx above 5% for 5 minutes, CPU above 85% for 10 minutes.
- **Guards against false positives**: the error-rate alert also requires real traffic, so one failed request on an idle API does not fire.
- **Grouping and deduplication** in Alertmanager (`group_by: [alertname, tier]`, `group_wait`, `group_interval`) so related alerts arrive as one message, and a long
  `repeat_interval` (4h) so an unresolved alert is not repeated every minute.
- **Severity and tier labels and actionable annotations** (summary and description) so the receiver knows how urgent it is and where to look.
- **Resolved notifications**, so people know when to stop worrying.
- **Inhibition and silences** (for example mute service alerts while the host is known to be down) and **regular review**: delete or retune any alert that nobody acted on.
