# Metrics: Prometheus and exporters

| Service | Image (pinned) | Networks | Role |
|---|---|---|---|
| `prometheus` | `prom/prometheus:v3.16.0` | metrics, monitoring | Scrapes, stores (15 d / 2 GiB), evaluates recording rules |
| `node-exporter` | `prom/node-exporter:v1.12.1` | metrics | Host (Docker VM) CPU, memory, disk, network |
| `postgres-exporter` | `quay.io/prometheuscommunity/postgres-exporter:v0.20.1` | application, metrics | PostgreSQL metrics, as the `pg_monitor` role |

None of them publishes a port, none has internet egress (all their networks are internal), and
all run as `nobody` with a read-only root filesystem, all capabilities dropped and
`no-new-privileges`. The backend (already on `metrics`) exposes `/metrics`
(see `backend.md`).

## Scrape jobs (`monitoring/prometheus/prometheus.yml`)

Interval 15 s, timeout 10 s, external label `environment=local`.

| Job | Target | Network |
|---|---|---|
| `prometheus` | `localhost:9090` | - |
| `backend` | `backend:8000/metrics` | metrics |
| `node` | `node-exporter:9100` | metrics |
| `postgres` | `postgres-exporter:9187` | metrics |
| `loki` | `loki:3100` | monitoring (Phase 7) |
| `alloy` | `alloy:12345` | monitoring (Phase 7) |

Loki and Alloy are scraped since Phase 7. There is no Alertmanager: alerting is Grafana
Alerting (Phase 8), so Prometheus holds recording rules only.

## Storage and access

- Named volume `monitoring-3tier_prometheus_data` at `/prometheus`; data survives restarts
  (verified).
- Retention 15 days **and** 2 GiB, whichever hits first.
- `--web.enable-lifecycle` and `--web.enable-admin-api` are **off**. To reload the configuration or
  rules: `docker kill -s HUP monitoring-3tier-prometheus-1` (or restart the container).
- Prometheus itself is not published. Its web UI is available on **http://127.0.0.1:9090** through the
  `prometheus-ui` forwarder (localhost only; see `security.md`). Or query it with Grafana (Phase 6, `docs/grafana.md`; Explore or the dashboards) or a throw-away container on the
  `monitoring` network:

```sh
docker run --rm --network monitoring-3tier_monitoring curlimages/curl -s -G \
  http://prometheus:9090/api/v1/query --data-urlencode 'query=up'
```

## Recording rules (`monitoring/prometheus/rules/recording.yml`)

Used by the dashboards (Phase 6) and alerts (Phase 8). Unit-tested with `promtool`
(`tests/prometheus/recording_rules_test.yml`).

| Rule | Meaning |
|---|---|
| `app:http_requests:rate5m`, `app:http_requests_by_route:rate5m` | Request rate, total and by method/path/status |
| `app:http_errors:ratio_rate5m` | Share of 5xx responses. **0 (not absent) when there are no 5xx series or no traffic** |
| `app:http_request_duration_seconds:p95_5m` | p95 latency |
| `app:db_query_duration_seconds:p95_5m` | p95 database statement latency |
| `app:db_pool_utilisation:ratio` | Checked-out / (checked-out + checked-in) connections |
| `instance:node_cpu_utilisation:ratio` | Busy time over core count (see note) |
| `instance:node_memory_utilisation:ratio` | `1 - MemAvailable/MemTotal` |
| `instance:node_filesystem_utilisation:ratio` | Used share of the Docker data disk (`device="overlay"`) |
| `postgres:connections:ratio` | Open connections / `max_connections` |
| `postgres:transactions:rate5m` | Commits + rollbacks per second |

**CPU note (Docker Desktop / WSL2):** `1 - idle` reads about 90 % on an idle VM because the
idle counters under-tick. The rule divides the non-idle (excluding iowait and steal) rate by the
core count, which is correct on ordinary Linux too.

## node-exporter on Docker Desktop

- It reports the **Linux VM** (CPU, memory, network come from `/proc`, which is not namespaced),
  not Windows.
- **No host mount at all.** An earlier draft bind-mounted `/` read-only (the usual recommendation).
  Testing showed that on Docker Desktop this lets the container read your Windows drives through
  `/mnt/host/*`, including project files such as `.env`, so the mount was removed.
- Disk: the container's root filesystem is an overlay whose usage is that of the **Docker data
  disk**, the one that fills up with images and volumes. Only the root mountpoint `/` is kept
  (`--collector.filesystem.mount-points-exclude=^/.+`), so the filesystem rule returns a single
  series, `device="overlay"`. Windows drive usage (`C:`, `D:`) is deliberately *not* collected.
  On a native Linux host the same setup reports the disk holding Docker's data root.
- It never uses host networking or `pid: host`.

## postgres-exporter

Connects to `postgres:5432` database `tasks` as `EXPORTER_DB_USER` (member of `pg_monitor`,
`NOSUPERUSER`, no write rights) over the internal `application` network without TLS. The
password is an environment variable (see decision #29).

## Verifying

```sh
sh tests/e2e/check_phase5.sh      # promtool, targets, rules, hardening, secrets, isolation
docker compose logs prometheus     # JSON logs
```
