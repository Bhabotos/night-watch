# Night Watch: Evidence Log

Module 6 evidence, recorded from real command output. Nothing here is claimed without a test run.
Date of capture: 2026-11-21. Stack: Compose project `monitoring-3tier`, branch `main` (changes uncommitted).

## Phase 2 changes

| File | Change |
|---|---|
| `docker-compose.yml` | Added `blackbox-exporter` (v0.28.0) and `alertmanager` (v0.28.1). Existing services untouched. |
| `monitoring/prometheus/prometheus.yml` | Added `alerting:` block and jobs `frontend-blackbox`, `blackbox`, `alertmanager`. Existing jobs unchanged. |
| `monitoring/blackbox/blackbox.yml` | New. Module `http_2xx`. |
| `monitoring/alertmanager/alertmanager.yml` | New. Telegram receiver with placeholders only. |
| `monitoring/prometheus/rules/alerts.yml` | New. 9 alert rules. The 11 recording rules are unchanged. |
| `tests/prometheus/alerts_test.yml` | New. 8 promtool unit tests for the alert rules. |
| `.env.example` | Appended `TELEGRAM_BOT_TOKEN=` and `TELEGRAM_CHAT_ID=` (empty). `.env` was not touched. |

Design notes:
- Only the two new containers were created (`docker compose up -d blackbox-exporter alertmanager`, preceded by `--dry-run`).
- Prometheus was reloaded with `SIGHUP`, not restarted. `StartedAt` and `RestartCount=0` were identical before and after.
- Blackbox joins `edge` (where nginx lives) and `metrics`; this avoids recreating nginx. Alertmanager joins `monitoring` (Prometheus) and `edge` (the only route to Telegram). Neither publishes a host port.
- Telegram token and chat id are injected from environment variables at container start and never stored in a tracked file.

## Validation results

### promtool / amtool
```
promtool check config   -> SUCCESS (in the running Prometheus container, 2 rule files)
promtool check rules    -> alerts.yml: 9 rules found; recording.yml: 11 rules found
promtool test rules alerts_test.yml          -> SUCCESS
promtool test rules recording_rules_test.yml -> SUCCESS (existing tests still pass)
amtool check-config alertmanager.yml         -> SUCCESS (1 receiver)
docker compose config -q                     -> OK
```

### Blackbox probe
```
probe_success 1  probe_http_status_code 200  probe_duration_seconds 0.0022   (target http://nginx:8080/)
negative test, target http://nginx:9999/  ->  probe_success 0
```

### Prometheus targets (`/api/v1/targets`): 9 of 9 UP
```
alertmanager       up   http://alertmanager:9093/metrics
alloy              up   http://alloy:12345/metrics
backend            up   http://backend:8000/metrics
blackbox           up   http://blackbox-exporter:9115/metrics
frontend-blackbox  up   http://blackbox-exporter:9115/probe?module=http_2xx&target=http://nginx:8080/
loki               up   http://loki:3100/metrics
node               up   http://node-exporter:9100/metrics
postgres           up   http://postgres-exporter:9187/metrics
prometheus         up   http://localhost:9090/metrics
```
`/api/v1/alertmanagers` lists `http://alertmanager:9093/api/v2/alerts` as active.

### Rules loaded in Prometheus
All 9 alert rules are `inactive` (healthy system). Recording rules: application 6, host 3, postgres 2 (11, unchanged).

### PromQL queries and actual results
| Query | Result |
|---|---|
| `probe_success{job="frontend-blackbox"}` | `1` |
| `app:http_requests:rate5m` | `0.1263` req/s |
| `instance:node_cpu_utilisation:ratio` | `0.0653` (6.5%) |
| `instance:node_memory_utilisation:ratio` | `0.3622` (36.2%) |
| `pg_up` | `1` |
| `postgres:connections:ratio` | `0.04` |
| `app:http_errors:ratio_rate5m` | `0` |
| `ALERTS` | empty (nothing firing) |

### Existing stack health
All 11 original containers are `healthy` with unchanged uptime (5 hours). Frontend `http://127.0.0.1:8088/` returned 200,
`/api/v1/tasks` through nginx returned 200, Grafana `/api/health` returned 200. Existing ports 8088, 3001 and 9090 are
unchanged. The five named volumes are intact. The four dashboards are unchanged.

### Cleanup of the experimental stack
The 8 containers of Compose project `night-watch` (working dir `D:\Module-6-Night-Watch`) were identified by label and stopped
with `docker compose -p night-watch down` (no `-v`, no `--rmi`). Its volumes (`night-watch_postgres_data`,
`night-watch_prometheus_data`), images and files were preserved.

## Not yet done
- Real Telegram delivery (credentials are not configured: Alertmanager logs `telegram: NOT configured`).
- Controlled alert firing and resolved demonstration.
- Grafana dashboards for Tasks 3 and 4, GitHub Actions, README answers.

## Screenshots to capture (Task 1)
1. Prometheus UI `http://127.0.0.1:9090/targets`: all 9 targets UP.
2. `http://127.0.0.1:9090/alerts`: the 9 alert rules (inactive).
3. Graph tab with `probe_success{job="frontend-blackbox"}` and one other query.
4. Terminal showing `docker compose ps` with all services healthy.
Alertmanager has no host port; inspect it with `docker exec monitoring-3tier-alertmanager-1 wget -qO- http://127.0.0.1:9093/api/v2/status`.

---

# Phase 3: Grafana dashboards (2026-11-21)

## Files
| File | Change |
|---|---|
| `monitoring/grafana/dashboards/night-watch/node-exporter-full-1860.json` | New. Community dashboard **Node Exporter Full**, grafana.com ID **1860**, revision **46** (updated 2026-10-31), downloaded and committed unmodified except `id: null` and two added tags. It uses the `ds_prometheus` datasource variable, so it binds to the provisioned Prometheus. |
| `monitoring/grafana/dashboards/night-watch/three-tier-production.json` | New. Dashboard **Three-Tier App – Production** (uid `three-tier-production`). |

No provisioning file, compose file or existing dashboard changed. The existing provider (`dashboards.yml`) scans `/var/lib/grafana-dashboards`
recursively, so the `night-watch/` subfolder was picked up within 30 seconds with no Grafana restart (start time unchanged, 0 restarts).
The subfolder also keeps `tests/e2e/dashboards_lint.py` (which expects exactly the original four) passing unchanged.

## Three-Tier App – Production: 19 panels in 4 rows; types: stat, gauge, timeseries, table
| Row | Panel | Type | PromQL |
|---|---|---|---|
| Frontend | Frontend availability | stat (UP/DOWN) | `min(probe_success{job="frontend-blackbox"})` |
| Frontend | Availability (selected range) | stat | `avg_over_time(probe_success{job="frontend-blackbox"}[$__range])` |
| Frontend | HTTP status code | stat | `max(probe_http_status_code{job="frontend-blackbox"})` |
| Frontend | Frontend probe duration | timeseries | `probe_duration_seconds{job="frontend-blackbox"}` |
| Backend API | Request rate | stat | `app:http_requests:rate5m` |
| Backend API | Error rate (5xx) | gauge | `app:http_errors:ratio_rate5m` |
| Backend API | Response time p95 | stat | `app:http_request_duration_seconds:p95_5m` |
| Backend API | Request rate by status | timeseries | `sum by (status) (app:http_requests_by_route:rate5m)` |
| Backend API | Response time (p50 / p95) | timeseries | `app:http_request_duration_seconds:p95_5m`; `histogram_quantile(0.5, sum by (le) (rate(http_request_duration_seconds_bucket{job="backend"}[$__rate_interval])))` |
| Backend API | Error rate over time | timeseries | `app:http_errors:ratio_rate5m` |
| Backend API | Requests by route | table | `sort_desc(sum by (method, path) (app:http_requests_by_route:rate5m))` |
| Database | PostgreSQL health | stat (UP/DOWN) | `min(pg_up{job="postgres"})` |
| Database | Connection usage | gauge | `postgres:connections:ratio` |
| Database | Open connections | stat | `sum(pg_stat_activity_count{job="postgres"})` |
| Database | Connections by state | timeseries | `sum by (state) (pg_stat_activity_count{job="postgres", state=~"active\|idle\|idle in transaction"})`; `max(pg_settings_max_connections{job="postgres"})` |
| Server | CPU usage | gauge | `instance:node_cpu_utilisation:ratio` |
| Server | Memory usage | gauge | `instance:node_memory_utilisation:ratio` |
| Server | Disk usage | gauge | `max(instance:node_filesystem_utilisation:ratio)` |
| Server | CPU / memory / disk over time | timeseries | the three recording rules above |

Gauge thresholds match the alert rules (error rate 5%, connections 80%, CPU 85%, memory 90%, disk 85%). Every metric name
already existed in Prometheus (checked before use); no exporter was added. Disk is the Docker data disk behind the VM, not the Windows drives.

## Validation results
- Grafana `/api/search`: 6 dashboards in folder *Monitoring* (the original 4 plus Node Exporter Full `rYdddlPWk` and `three-tier-production`).
- Both new dashboards report `provisioned = true`; production has 23 entries (19 panels + 4 rows), 1860 has 28.
- Datasource `prometheus` health: `OK - Successfully queried the Prometheus API.`
- Every query of the production dashboard run through Grafana `/api/ds/query`: **23 of 23 returned data, 0 empty, 0 errors**.
- Node Exporter Full: **255 queries returned data, 46 returned no data, 0 errors**. The empty ones need collectors that the Docker Desktop VM
  does not expose or that are not enabled here (systemd, hwmon temperature and fan, TCP connection states, process counts, CPU frequency,
  IRQ, pressure stall, Zswap, ECC). CPU, memory, disk, network, load and I/O panels have data. Node Exporter deliberately has no host access in this project.
- Grafana logs: no dashboard or provisioning errors.
- Existing: `dashboards_lint.py` 0 failures; the 11 original containers still healthy with unchanged uptime (plus alertmanager and blackbox-exporter); 5 volumes intact.

## Known issues (existing files not modified)
- `tests/e2e/check_phase6.sh` hard-codes exactly 4 dashboards (`app-tasks,host-vm,logs,postgres` and `dash_count = 4`) and will now report
  failures. Its expected set needs updating to 6, or it needs to ignore the `night-watch` subfolder (needs your approval).
- `tests/e2e/grafana_panels_check.py` crashes with `KeyError: 'datasource'` on dashboard 1860, whose targets use the dashboard datasource
  variable. The checks above used a separate scratch script instead.

## Screenshots still required (Tasks 2, 3, 4)
1. `http://127.0.0.1:3001` (sign in): Connections > Data sources > Prometheus > "Save & test" showing success (Task 2).
2. Dashboards list showing both new dashboards in folder *Monitoring* (Tasks 2, 3, 4).
3. **Node Exporter Full** with job `node` and instance `node-exporter:9100`, showing the CPU, Memory and Disk panels (Task 3).
4. **Three-Tier App – Production**, all four rows visible (scroll or zoom out), after loading a few pages at `http://127.0.0.1:8088` so the request panels show activity (Task 4).
5. The frontend panel showing DOWN is deferred to the Phase 4 alert demonstration.

---

# Phase 4: Test fixes and Telegram alerting (2026-11-22)

## Part A: Phase 3 issues fixed (all tests run, real output)

| File | Change |
|---|---|
| `tests/e2e/check_phase6.sh` | The brittle "exactly 4 dashboards" checks (exact uid list and `dash_count = 4`) are replaced by `dash_present`, which requires the six dashboards **by uid and title** (`app-tasks`, `host-vm`, `postgres`, `logs`, `rYdddlPWk` = "Node Exporter Full", `three-tier-production` = "Three-Tier App – Production") and allows others. |
| `tests/e2e/check_phase7.sh` | The same brittle uid-list check on the Logs dashboard now only requires `logs` to be present. Syntax-checked only (the script was not run: it restarts services). |
| `tests/e2e/grafana_panels_check.py` | Walks panels nested in collapsed rows; targets inherit the panel datasource; the `${ds_prometheus}` datasource variable resolves to the real uid; `label_values(...)` query variables (`job`, `nodename`, `node`) resolve to real values instead of "match everything"; credentials are read lazily so the module is importable in tests; metrics of collectors the Docker VM lacks are allow-listed only for dashboard 1860 (`ALLOW_EMPTY_METRICS`); the Logs stat "Errors and critical" (an error-line count that is empty in a quiet hour, like its already-allowed sibling) joined `ALLOW_EMPTY`. |
| `tests/e2e/test_grafana_panels_check.py` | **New permanent regression tests** (12, offline, no Grafana or credentials): nested-panel walking, datasource inheritance and variable resolution, `label_values` variable resolution, every Node Exporter Full query resolves to Prometheus (150+ queries), the six required dashboards by uid and title, unique uids and titles, and the production dashboard requirements (6+ panels, 3+ types, rows per tier, required metrics). |

Results:
```
python -I -m unittest discover -s tests/e2e -p "test_*.py"   -> Ran 12 tests ... OK
python -I tests/e2e/dashboards_lint.py                        -> 0 failure(s)
python -I tests/e2e/grafana_panels_check.py                   -> 406 queries checked, 0 failed   (all 6 dashboards, through Grafana)
PERSISTENCE=0 sh tests/e2e/check_phase6.sh                    -> 49 PASS, 0 FAIL, exit 0
```
`check_phase6.sh` was run with `PERSISTENCE=0` because its default restarts services, which was not allowed. Two defects were found and fixed along the way:
(1) a fixture mistake in my own unit test, and (2) a Windows encoding issue (Python read curl output as cp1252, garbling the en dash), fixed with `-X utf8`.
Before the fix, the old checker crashed on dashboard 1860 (`KeyError: 'datasource'`).

## Part B: Telegram alerting

### Status: BLOCKED on credentials (not configured; nothing invented)
`TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` are not present in `.env`; the running Alertmanager logs `telegram: NOT configured`.
Per the safety rules the controlled demonstration was **not** run: nginx was not stopped (`StartedAt` unchanged) and all 13 containers are healthy.

### What was verified without credentials
- `amtool check-config` on `monitoring/alertmanager/alertmanager.yml`: SUCCESS (after setting `group_interval: 1m`, so that the *resolved* message follows recovery within about a minute instead of up to 5).
- The container's credential-injection logic, run in throwaway `--network none` containers with **fake** values:
  - both variables set (fake token, chat id `-1001234567890`): prints `telegram: configured`, the `chat_id` line is rewritten, the token file is written (15 bytes), `amtool check-config` SUCCESS;
  - non-numeric chat id (`1; rm -rf /`): rejected, placeholders kept, token file empty, config valid (no shell injection);
  - nothing set: placeholders kept, config valid.
- `tests/e2e/alert_demo.sh` (new): syntax OK, and it **aborts with exit 2 before touching anything** when Telegram is not configured.

### Secure setup (you do this; nothing is pasted into chat or tracked files)
1. In Telegram, open **@BotFather**, send `/newbot`, follow the prompts and keep the token it returns.
2. Open a chat with your new bot and send it any message (or add it to a group and send a message there).
3. Find the chat id: in a **private browser window** open `https://api.telegram.org/bot<YOUR_TOKEN>/getUpdates` and read `"chat":{"id": ...}` (negative for groups). Close the window.
4. Add two lines to `D:\monitoring-3tier-project\.env` with a text editor (this file is gitignored; do not paste the values anywhere else):
   ```
   TELEGRAM_BOT_TOKEN=<token from BotFather>
   TELEGRAM_CHAT_ID=<numeric chat id>
   ```
5. Apply it by recreating only Alertmanager: `docker compose up -d alertmanager`. Then check: `docker logs monitoring-3tier-alertmanager-1 2>&1 | head -1` must print `telegram: configured`.
6. Optional delivery test (sends one message after about 30 s):
   `docker exec monitoring-3tier-alertmanager-1 amtool alert add NightWatchTest severity=warning --annotation=summary="Night Watch Telegram test" --alertmanager.url=http://127.0.0.1:9093`
7. Tell me when done and I will run `sh tests/e2e/alert_demo.sh`. If the token ever leaks, send `/revoke` to BotFather and generate a new one.

### Demonstration plan (`tests/e2e/alert_demo.sh`, about 8 minutes)
Stops **only** `monitoring-3tier-nginx-1` (restored automatically, even on Ctrl-C), and prints a timestamped evidence line for each step:
frontend `probe_success=0` -> `FrontendDown` firing in Prometheus -> active in Alertmanager -> Telegram firing notification (Alertmanager's
`alertmanager_notifications_total{integration="telegram"}` rises, `..._failed_total` stays 0) -> nginx restarted and healthy -> `probe_success=1` -> alert resolved ->
Telegram resolved notification. The script cannot read the Telegram chat, so **you** must screenshot the two messages.

### Screenshots still required for Task 5
1. Prometheus `http://127.0.0.1:9090/alerts` with `FrontendDown` **FIRING**.
2. Telegram chat showing the FIRING message.
3. Production dashboard "Frontend availability" showing **DOWN** during the outage (optional but strong).
4. Prometheus `/alerts` after recovery (resolved) and the Telegram RESOLVED message.

---

# Task 5 review against the rubric (2026-11-22)

Source: `Module_6_Night_Watch_Assignment_Execution_Plan.docx` (Downloads), Phase 5 / Task 5, 20 marks.
The rubric says: "Configure a notification contact point **such as email, Slack, Discord or Telegram**." Telegram is one example, **not mandatory**.

## Rubric checklist

| Requirement | Status | Evidence |
|---|---|---|
| Rule: any application tier down | Done | `FrontendDown`, `BackendDown`, `PostgresDown` (`for: 1m`, critical); promtool unit tests pass |
| Rule: Backend API error rate too high | Done | `BackendHighErrorRate` (5xx > 5% for 5m, idle-traffic guard); unit tests incl. the idle no-fire case |
| Rule: server resource usage too high | Done | `HostHighCpu` (85%, 10m), `HostHighMemory` (90%, 5m), `HostDiskAlmostFull` (85%, 10m); rule logic validated by unit tests (rubric allows this for the server rule) |
| Documented thresholds and sustained `for` | Done in `alerts.yml` | README write-up still to do |
| Avoid alert fatigue: grouping, labels, annotations | Done | `group_by [alertname, tier]`, `severity`/`tier` labels, summary + description annotations, 4h repeat |
| Notification contact point configured | **Partial** | Telegram receiver (placeholders, no credentials) and a new local webhook receiver `alert-sink` are defined and `amtool check-config` passes, but the running Alertmanager has **not yet loaded** the webhook route |
| Notification policy routes alerts to the channel | **Partial** | Route written (`local-webhook`, `continue: true`, default Telegram); not yet loaded |
| Tokens and webhook URLs not in source | Done | env-injected; no secrets in tracked files |
| Deliberately fail one tier, show firing then resolved | **Not done** | `tests/e2e/alert_demo.sh` ready |
| Capture notification delivery | **Not done** | same |

## Fastest safe channel
A **local webhook receiver** (`alert-sink`): zero credentials, no outbound connection, no published port, nothing to sign up for.
Alertmanager POSTs firing and resolved notifications to it and each is logged as a JSON line (also collected into Loki by Alloy).
Telegram stays configured as a second receiver for when credentials exist. Limitation: it is a machine receiver, not a human chat message. A real
channel is stronger evidence for a grader. The next-fastest real channel is a **Discord webhook** (one URL from Channel Settings > Integrations >
Webhooks; no bot, no chat id), which would need roughly ten more config lines once the URL exists.

## Changes made for this review
- New: `monitoring/alert-sink/sink.py` and service `alert-sink` in `docker-compose.yml` (python 3.12 image already on this machine, non-root,
  read-only rootfs, cap_drop ALL, 64M, `monitoring` network only). Healthy; a simulated POST was logged correctly (direct self-test, not an Alertmanager notification).
- `monitoring/alertmanager/alertmanager.yml`: added receiver `local-webhook` and a `continue: true` child route. Existing rules, Telegram receiver, timings unchanged.
- `tests/e2e/alert_demo.sh`: `CHANNEL=webhook` (default) or `CHANNEL=telegram`. It refuses to run (exit 2, nothing touched) until the chosen channel is live; this was verified.

## Blocker
The running Alertmanager reads its config at start-up, so it must be **restarted (or recreated)** to load the new route. The Phase 4 safety rule said not to stop Alertmanager,
so this was not done and the demo was not run. nginx is untouched (start time unchanged).

---

# Task 5 demonstration: controlled frontend failure (2026-11-21, 18:14-18:17 UTC; 2026-11-22 local, UTC+6)

Channel: **local webhook receiver** (`alert-sink`), chosen from the rubric's "contact point such as email, Slack, Discord or Telegram" as the fastest channel
that needs no credentials. Telegram stays optional and unconfigured.

## Preparation and checks
| Step | Result |
|---|---|
| `amtool check-config` before restart | SUCCESS |
| Running Alertmanager before restart | `local-webhook` receiver **not** loaded |
| `docker restart monitoring-3tier-alertmanager-1` (only this container) | healthy again; start time changed `17:26:49Z` -> `18:13:47Z` |
| Loaded config after restart (`/api/v2/status`) | `route.routes: [receiver: local-webhook, continue: true]` and receiver `local-webhook` with `send_resolved: true` (webhook URL is masked by Alertmanager as `<secret>`) |
| Prometheus -> Alertmanager | `http://alertmanager:9093/api/v2/alerts` still active |
| Baseline | 14 containers healthy (11 original + blackbox-exporter, alertmanager, alert-sink); `probe_success=1`; `FrontendDown` inactive |

## Timeline (`CHANNEL=webhook sh tests/e2e/alert_demo.sh`, raw output)
```
[18:14:28Z] BASELINE  probe_success=1 FrontendDown=none
[18:14:28Z] STEP 1  stopping ONLY monitoring-3tier-nginx-1
[18:14:40Z] EVIDENCE frontend availability failure: probe_success=0
[18:15:54Z] EVIDENCE alert FIRING in Prometheus: FrontendDown=firing
[18:15:55Z] EVIDENCE alert ACTIVE in Alertmanager: FrontendDown (count=1)
[18:16:25Z] EVIDENCE webhook firing notification: sent=1 (was 0)
    receiver got: FIRING FrontendDown severity=critical startsAt=2026-11-21T18:15:35.362Z endsAt=0001-01-01T00:00:00Z
[18:16:26Z] STEP 2  recovery: starting monitoring-3tier-nginx-1
[18:16:34Z] EVIDENCE nginx healthy
[18:16:34Z] EVIDENCE frontend recovered: probe_success=1
[18:16:50Z] EVIDENCE alert RESOLVED in Prometheus: FrontendDown=none
[18:17:25Z] EVIDENCE webhook resolved notification: sent=2 (was 1)
    receiver got: FIRING FrontendDown ...
    receiver got: RESOLVED FrontendDown severity=critical startsAt=2026-11-21T18:15:35.362Z endsAt=2026-11-21T18:16:35.362Z
[18:17:27Z] FINAL    probe_success=1 FrontendDown=none alertmanager_active=0
```
(The original run's BASELINE and FINAL lines were mislabelled `telegram_sent`; the values are the **webhook** counter. The script was corrected afterwards.)

Durations: probe failed 12 s after the stop; alert pending then firing about 1 m 26 s after the stop (`for: 1m`); notification delivered 31 s later (`group_wait: 30s`); resolved
notification about 50 s after recovery (`group_interval: 1m`).

## After the demonstration
- nginx restarted automatically by the script: healthy, start time `18:16:26Z`, `RestartCount=0`, frontend `http://127.0.0.1:8088/` returned 200.
- All 14 containers healthy. Only nginx and (before the demo) Alertmanager were stopped/restarted; Prometheus, Grafana, Loki, Alloy, Blackbox, the backend and PostgreSQL were not.
- Alertmanager counters: `alertmanager_notifications_total{integration="webhook"} = 2`; `alertmanager_notifications_failed_total{integration="webhook"}` = 0 for every reason.
- No credentials were used or printed.

## Finding fixed afterwards
`telegram` notifications total was 0: in Alertmanager a parent route's receiver only handles alerts that **no child route matches**; `continue` only moves on to sibling routes. So the earlier
comment claiming Telegram would still receive alerts was wrong. The comment in `alertmanager.yml` now says to add an explicit `- receiver: telegram` route to enable it. This was a comment-only change
and the running Alertmanager was not reloaded. (Webhook-only delivery is exactly what the demonstration used.)

## Task 5 status
Rubric items satisfied: 3+ alert rules (tier down, API error rate, server resources), documented thresholds and sustained `for`, grouping/labels/annotations, notification contact point and routing configured and
loaded, secrets kept out of source, one tier deliberately failed with alert **firing**, **notification delivered**, tier recovered and alert **resolved**.
Still missing: screenshots (the demo ran from a script; nothing was screenshotted) and, optionally, a human-readable channel (Discord/Telegram). The API error-rate and server-resource rules were validated by unit tests, not by live load.

## Screenshots to capture (rerun the demo, about 4 minutes, with the UIs open)
1. Prometheus `http://127.0.0.1:9090/alerts`: `FrontendDown` **FIRING** (and PENDING a minute earlier).
2. Grafana "Three-Tier App – Production": Frontend availability **DOWN**, then **UP**.
3. Terminal showing the timeline above, and `docker logs monitoring-3tier-alert-sink-1` with the FIRING and RESOLVED lines.

---

# Phase 5: Docker re-verification and local CI validation (2026-11-22, 04:07-04:20 UTC = 10:07-10:20 Bangladesh time, UTC+6)

Time convention: all log times are UTC. The Task 5 demo above ran at 18:14-18:17 UTC on 2026-11-21, which is 00:14-00:17 on 2026-11-22 in Bangladesh.

## Docker state after starting Docker Desktop (04:07 UTC)
- Docker context `desktop-linux`; nothing was removed, recreated or pruned.
- Compose project `monitoring-3tier`: 14 containers exist; **13 healthy, 1 exited**: `monitoring-3tier-prometheus-1` is `Exited (255)`
  (finished 04:07:20Z, no OOM, no error, restart policy `unless-stopped`; the last log line is a normal config reload at 17:27Z on 21 Nov, i.e. an unclean stop when the Docker VM shut down).
  **Not corrected yet** (awaiting approval; `docker start monitoring-3tier-prometheus-1` would be the minimal fix). Consequence: `127.0.0.1:9090` returns no response, so Prometheus targets, datasource health and live dashboard queries could not be re-verified in this session.
- Volumes of the project: `monitoring-3tier_{alloy,grafana,loki,postgres,prometheus}_data` (5, intact). The machine also holds other projects' containers and volumes (not touched).
- Verified live: frontend `http://127.0.0.1:8088/` 200; Grafana `/api/health` `database: ok`; Alertmanager `/-/healthy` OK, loaded config contains receiver `local-webhook`, no explicit Telegram route (as documented);
  Blackbox probe of `http://nginx:8080/` -> `probe_success 1`, `probe_http_status_code 200`; `alert-sink` log still holds the demo's `FrontendDown` **firing** and **resolved** lines (persistent evidence for Task 5).
- Alertmanager's in-memory counter `alertmanager_notifications_total{integration="webhook"}` is 0 again because Alertmanager restarted at 04:07:25Z; the sink log, not the counter, is the lasting proof.

## Local validation (real output)
```
sh scripts/validate_monitoring.sh -> 19 checks PASS, 0 FAIL: "RESULT: all validation checks passed"
  (compose config, promtool check config/rules, promtool test rules x2, amtool check-config, blackbox --config.check,
   6 dashboard JSON files, dashboard lint, 12 dashboard regression tests, 16 workflow tests, .env untracked, no token/private key)
python -I -m unittest discover -s tests/e2e -p "test_*.py" -> Ran 12 tests OK
python -I -m unittest discover -s tests/ci  -p "test_*.py" -> Ran 16 tests OK
Workflow YAML parsed with PyYAML: validate = pull_request, workflow_call, workflow_dispatch; deploy = push (main); both permissions: contents: read
```
actionlint was **not** run (not installed, and pulling an unpinned image was declined).

## Negative test (`sh tests/ci/negative_test.sh`, works on a throw-away copy)
Defect found first: fault 5 reported `could not be applied` because line 45 held a literal control character (0x01) instead of the sed back-reference `\1`. Fixed in `tests/ci/negative_test.sh`. Result after the fix:
```
PASS  control: unmodified configuration passes (validation exit 0)
PASS  fault 1: invalid PromQL in an alert rule            (exit 1; caught by promtool check config, check rules, test rules)
PASS  fault 2: invalid scrape_interval in prometheus.yml  (exit 1; caught by promtool check config)
PASS  fault 3: Alertmanager route to an unknown receiver  (exit 1; caught by amtool check-config)
PASS  fault 4: truncated dashboard JSON                   (exit 1; caught by JSON validity and regression tests)
PASS  fault 5: dashboard renamed                          (exit 1; caught by the dashboard requirement tests)
RESULT: validation passes on valid config and fails on every injected fault
```
Expected failure for the GitHub "red run": the same fault 1 on a temporary branch fails `promtool check rules`. Afterwards `validate_monitoring.sh` passed again on the real repository (no real file was changed by the test).

## Not claimed
No GitHub Actions run exists. The repository `Bhabotos/night-watch` does not exist; nothing was committed, pushed or deployed.

---

# Phase 6: live re-verification and screenshots (2026-11-22, about 04:20-04:30 UTC = 10:20-10:30 Bangladesh time, UTC+6)

## Corrective action (approved)
`docker start monitoring-3tier-prometheus-1` only (non-destructive; no recreate, no compose down/prune). It became `healthy` within 25 s. All 14 project containers are now Up and healthy (`evidence/screenshots/06-docker-compose-ps.png`). The 5 `monitoring-3tier_*_data` volumes are intact.

## Results
| Check | Result |
|---|---|
| Prometheus targets | 9 of 9 UP (alertmanager, alloy, backend, blackbox, frontend-blackbox, loki, node, postgres, prometheus) |
| Alert rules | 9 loaded, all `inactive`; Alertmanager `http://alertmanager:9093/api/v2/alerts` active |
| Grafana datasource | `Prometheus` (uid `prometheus`, provisioned, read-only): "Successfully queried the Prometheus API." |
| `grafana_panels_check.py` (6 dashboards) | First run **406 queries, 3 failed** (Application "Requests per second by route", "p95 latency by route", Logs "Backend requests (app.access)"): NO DATA because Prometheus had been down and there was no recent traffic. After sending ~100 normal requests to the frontend: **406 queries, 0 failed** |
| Alertmanager | healthy; `local-webhook` receiver loaded; no Telegram route (unchanged) |
| alert-sink | healthy; log holds the demo's `FrontendDown` firing (startsAt 2026-11-21T18:15:35Z) and resolved (endsAt 18:16:35Z). The first log line `SinkSelfTest` is a direct self-test POST, not an Alertmanager notification |
| Blackbox | `probe_success 1`, status 200 |

Note: Grafana also holds three **UI-created** datasources (`loki-1`, `loki-2`, `prometheus-1`, not read-only) next to the two provisioned ones. They are not in the repository and were left untouched.

## Screenshots (`evidence/screenshots/`)
| File | Content | How made |
|---|---|---|
| `01-grafana-dashboards-list.png` | Folder *Monitoring* with all 6 dashboards | headless Chrome, logged in as the Grafana admin |
| `02-node-exporter-full-1860.png` | Node Exporter Full, job `node`, instance `node-exporter:9100`, last 1 h | same |
| `03-three-tier-app-production.png` | Production dashboard, all 4 rows, after normal traffic, last 30 min | same |
| `04-prometheus-targets.png` | `/targets` (page shows the first 7 pools; the list continues below) | headless Chrome |
| `05-prometheus-alerts-inactive.png` | `/alerts`, all rules inactive | headless Chrome |
| `06-docker-compose-ps.png` / `.txt` | `docker compose ps` | **rendered from the captured text**, not a live terminal window |
| `07-alert-sink-firing-resolved.png` / `.txt` | alert-sink log | rendered from the captured text |

## Still not captured (needs a repeat of the frontend failure, not authorised yet)
`FrontendDown` **FIRING** in Prometheus `/alerts`, and the Grafana "Frontend availability" panel showing **DOWN**.


---

# Phase 7: second controlled FrontendDown demonstration with real screenshots (2026-11-22, 04:30-04:34 UTC = 10:30-10:34 Bangladesh time)

Run with the existing, unmodified script `CHANNEL=webhook sh tests/e2e/alert_demo.sh`. Pre-flight: 14 containers healthy, frontend 200 and bound to `127.0.0.1:8088` only (no real users),
`probe_success=1`, no `FrontendDown` alert. Only `monitoring-3tier-nginx-1` was stopped; Prometheus, Grafana, PostgreSQL and Alertmanager kept their start times and `RestartCount=0`.
Alerting configuration and routes were not changed. Raw log: `evidence/alert_demo_2026-11-22T0430Z.txt`.
```
[04:30:58Z] BASELINE  probe_success=1 FrontendDown=none sent=0 failed=0
[04:30:58Z] STEP 1  stopping ONLY monitoring-3tier-nginx-1
[04:31:14Z] EVIDENCE frontend availability failure: probe_success=0
[04:32:21Z] EVIDENCE alert FIRING in Prometheus: FrontendDown=firing
[04:32:22Z] EVIDENCE alert ACTIVE in Alertmanager: FrontendDown (count=1)
[04:32:54Z] EVIDENCE webhook firing notification: sent=1 (was 0), failed=0 (was 0)
[04:32:55Z] STEP 2  recovery: starting monitoring-3tier-nginx-1
[04:33:02Z] EVIDENCE nginx healthy
[04:33:07Z] EVIDENCE frontend recovered: probe_success=1
[04:33:23Z] EVIDENCE alert RESOLVED in Prometheus: FrontendDown=none
[04:33:52Z] EVIDENCE webhook resolved notification: sent=2 (was 1), failed=0
[04:33:54Z] FINAL    probe_success=1 FrontendDown=none alertmanager_active=0 sent=2 failed=0
```
After the run: nginx healthy (started 04:32:55Z, `RestartCount=0`), `http://127.0.0.1:8088/` returned 200, all project containers healthy.

## Screenshots made during the run (real headless-Chrome captures taken at the moments the script reported)
| File | Taken | Shows |
|---|---|---|
| `08-grafana-frontend-availability-DOWN.png` | 04:31:39Z | Production dashboard: Frontend availability **DOWN**, HTTP status 0, availability 95.24% |
| `09-prometheus-FrontendDown-FIRING.png` | 04:32:26Z | Prometheus `/alerts`: `FrontendDown` **FIRING (1)** in group application-tier-down |
| `10-prometheus-FrontendDown-after-recovery.png` | 04:33:28Z | `/alerts` after recovery: nothing firing (Prometheus drops a resolved alert; the RESOLVED notification is in the sink log) |
| `11-grafana-frontend-availability-recovered.png` | 04:33:37Z | Frontend availability back to UP |

## Local CI validation, re-run after the demo (2026-11-22)
`sh scripts/validate_monitoring.sh`: 19 checks, RESULT all passed. `sh tests/ci/negative_test.sh`: control passes; faults 1-5 each make validation exit 1 (invalid PromQL, invalid scrape_interval,
unknown Alertmanager receiver, truncated dashboard JSON, renamed dashboard); validation passed again afterwards. Final secret scan of tracked and untracked files: no matches; `.env` is gitignored.
Git: one commit (`86013df`, 2026-11-15), equal to `origin/main`; no commit, push, stash or tag was made during Night Watch work. This is local validation only: **no GitHub Actions run exists**, and
`Bhabotos/night-watch` does not exist yet.


---

# Phase 8: real GitHub Actions evidence (2026-11-22, 04:38-04:43 UTC = 10:38-10:43 Bangladesh time, UTC+6)

Repository: https://github.com/Bhabotos/night-watch (public, created 2026-11-22). Remote `night-watch` was added; `origin` (`monitoring-3tier-project`) is unchanged.
`main` on the new repository holds the pre-existing commit `86013df` (pushed so that a pull request has a base; it contains no workflows, so nothing ran). Nothing was merged and nothing was deployed.

| Item | Value |
|---|---|
| Submission branch / commit | `night-watch-submission` @ `f9eba60` (42 files; `.env` untracked; staged secret scan clean) |
| Pull request 1 (green) | https://github.com/Bhabotos/night-watch/pull/1 (`night-watch-submission` -> `main`, open, not merged) |
| Pull request 2 (negative test) | https://github.com/Bhabotos/night-watch/pull/2 (`ci-demo-invalid` -> `night-watch-submission`, open, not for merging) |

## Actions runs (workflow *Monitoring validation*, trigger `pull_request`; all verified with `gh run view`)
| Run | Commit | Result | What it proves |
|---|---|---|---|
| https://github.com/Bhabotos/night-watch/actions/runs/44986089290 | `f9eba60` | **success** (22 s job), all 19 checks PASS in the log | Normal validation on GitHub's runner |
| https://github.com/Bhabotos/night-watch/actions/runs/44986168079 | `05eb8f0` | **failure** (expected) | Validation catches a bad alert rule |
| https://github.com/Bhabotos/night-watch/actions/runs/44986230651 | `b4c97c8` | **success** | Validation passes again after the fix |

## Negative test: failure, reason and correction
- **Injected fault** (commit `05eb8f0`, branch `ci-demo-invalid`): in `monitoring/prometheus/rules/alerts.yml` line 15 the `BackendDown` expression `up{job="backend"} == 0` was changed to `up{job="backend" == 0` (closing brace removed).
- **Failure reason (from the run log):** `alerts.yml: 15:15: group "application-tier-down", rule 2, "BackendDown": could not parse expression: 1:18: parse error: unexpected "=" in label matching, expected "," or "}"`.
  Three checks failed: `promtool check config`, `promtool check rules` and `promtool test rules alerts_test.yml`; the other checks passed. The job ended with exit code 1 and the check was red. See `evidence/github-actions-red-run-log-excerpt.txt`.
- **Correction** (commit `b4c97c8`): the brace was restored; the branch then has no diff against `night-watch-submission`, and run 44986230651 is green.
- The fault was made in a separate git worktree outside the project folder, so the live bind-mounted `alerts.yml` and the running stack were never touched.
- The deploy workflow did not run (it triggers only on push to `main`), and no secrets were needed.

## Screenshots
`12-github-actions-green-run-pr1.png`, `13-github-actions-red-run-pr2-expected-failure.png`, `14-github-actions-green-after-fix-pr2.png` are real headless-Chrome captures of the public run pages. The page header shows "Sign in to view logs" (the logs are fetched with `gh`).

## Still open
Merging PR 1 into `main` (needs your approval; it would start the deploy workflow, which stops at the SSH step because no `production` secrets exist), Hetzner details and secrets, and an optional datasource "Save & test" screenshot.
