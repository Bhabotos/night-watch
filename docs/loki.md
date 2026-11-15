# Centralized logs: Loki, Alloy and the Docker socket proxy

```
containers (json-file logs) --Docker API--> docker-socket-proxy --(allow-list)--> Alloy --push--> Loki <--query-- Grafana
                                            (only Alloy may call it)  parse, label, mask          (not published)
```

| Service | Image (pinned) | Network | Role |
|---|---|---|---|
| `loki` | `grafana/loki:3.7.10` + busybox (healthcheck) | monitoring | Stores and queries logs. Filesystem storage on `loki_data`, 7-day retention |
| `alloy` | `grafana/alloy:v1.22.0` + busybox | monitoring | Discovers containers, parses, labels and masks lines, ships them to Loki. Runs as uid 473 |
| `docker-socket-proxy` | `wollomatic/socket-proxy:1.13.2` + busybox | monitoring | The **only** container with `docker.sock`. Answers Alloy only, and only for a short list of read calls |

None of the three is published, none has internet egress (the `monitoring` network is internal),
all run with a read-only root filesystem, all capabilities dropped and `no-new-privileges`.
The three tiny Dockerfiles only add one static `busybox` binary, because the upstream images have
no shell or `wget` and so cannot run a Docker `HEALTHCHECK`.

## What is collected

The stdout/stderr of every container of **this Compose project** (the discovery filter is the label
`com.docker.compose.project=monitoring-3tier`; other projects on the machine are ignored, verified).
`docker compose run` helper containers are skipped. Only the stack's own containers are collected,
which today are the ten services above plus `grafana`, `nginx`, `backend`, `postgres`, `prometheus`,
`node-exporter` and `postgres-exporter`.

## Labels (few, low-cardinality) and structured metadata

| Label | Values | Source |
|---|---|---|
| `job` | `docker` | constant |
| `service` | Compose service name (10 values) | Compose label |
| `container` | container name (10 values) | Docker |
| `level` | `debug info warning error critical unknown` | parsed (see below) |
| `log_type` | nginx only: `access`, `error`, `startup` | line shape |

Per-request values are **structured metadata**, not labels: `request_id`, `method`, `path`, `status`,
`upstream_status`, `route`, `logger`. They are searchable (`| request_id="..."`, `| status="404"`) but
not indexed, so they cannot explode the index. Measured on the running stack: 1 `job`, 10 `service`,
10 `container`, 5 `level` and 3 `log_type` values; about 25 streams in total. Loki's automatic
`service_name` / `detected_level` labels are switched off (`discover_service_name: []`).

## Parsing

| Source | Format | Parsed into |
|---|---|---|
| backend | JSON (`app/core/logging.py`) | timestamp, `level`, `request_id`, `logger`, `method`, `route`, `status` |
| nginx access | JSON, one line per request (`frontend/nginx/nginx.conf`) | timestamp, `request_id`, `method`, `path`, `status`; **level from the status**: 5xx = error, 4xx = warning, else info; busybox-wget health checks are dropped |
| nginx error | `2026/11/14 13:50:48 [error] 7#7: ...` | timestamp, `level` |
| PostgreSQL | `2026-11-14 13:13:03.249 UTC [1] LOG: ...` (`log_line_prefix`) | timestamp, `level` (LOG/NOTICE/STATEMENT/DETAIL = info, FATAL/PANIC = critical) |
| Prometheus, Grafana, Loki, Alloy, proxy | JSON | `level` |
| node-exporter, postgres-exporter | logfmt | `level` |

One severity vocabulary for all of them: `debug info warning error critical`, or `unknown` for lines
that carry no level. nginx and the backend share the **same `request_id`** (nginx generates it and the
backend reuses it), so one query finds a request in both services:

```logql
{job="docker"} | request_id="<id>"
```

In Grafana, the request id in a log line has a **"Whole request"** link (a derived field) that runs
exactly this query.

## Masking secrets (defence in depth)

Before anything is stored, Alloy masks values after `password`, `passwd`, `secret`, `token`,
`api_key` (as `key=value`, `key: value` or JSON), SQL `PASSWORD '...'` (PostgreSQL echoes failed
statements) and `Authorization: Bearer|Basic ...`. Harmless text such as `secretary=fine` is kept.
This is regular-expression masking: it is a second line of defence, **not a guarantee**. The first
line is that the applications do not log secrets (the backend redacts its DB password; nginx never logs
query strings). Environment variables are never read: Alloy's discovery exposes labels only.

**Loki's own query log is dropped.** Loki logs every query it runs *including the LogQL text*. A
search for a secret (in Explore or in a script) would store that secret in Loki as a log line, and each
dashboard refresh would feed back into the logs it reads. Alloy drops those lines (`"query":"`); they
remain visible with `docker logs loki`. See "A real leak found and fixed" in `security.md`.

## Retention, limits and disk

- 7 days (`retention_period: 168h`, compactor retention on). Loki has no size-based retention: size
  the volume for your log volume. Guard rails: 4 MB/s ingestion, 2000 streams, 12 label names, 256 KB lines.
- `delete_request_cancel_period: 1m` (Loki's default is 24 h): deletes are applied after a minute. The
  delete API is only reachable on the internal `monitoring` network.
- The containers themselves use Docker's default `json-file` log driver **without rotation**, so
  `docker logs` files grow without bound. Not changed here (Phases 1-6 are frozen); a Phase 9 item.

## Restart durability: what was lost, why, and the fix

**Symptom (found by the Phase 7 suite).** After a Loki restart, recently ingested log lines were missing:
4 warning-level nginx access lines (404 and 413 responses) written in the minutes before the restart,
while the backend lines, the nginx info lines and all older lines were intact. The container logs
confirmed the requests had happened.

**Where the loss was NOT** (each tested, none of them lost a line):
- **Alloy's delivery.** Alloy's write counters showed 3,543 entries sent and 0 dropped for every reason
  (`batch_too_large`, `ingester_error`, `queue_is_full`, `rate_limited`, `stream_limited`). During Loki's
  restarts Alloy received HTTP 500 `empty ring` and connection errors, retried them (8 retries) and got
  them accepted. A deliberate outage (Loki stopped while requests were made, then started) delivered every
  line. Re-creating Alloy right after traffic, twice, lost nothing and duplicated nothing.
- **Alloy's read positions.** Alloy keeps one cursor per container in `positions.yml` on the `alloy_data`
  volume; it advances when a line is *read*, and the in-memory write queue is retried until Loki accepts
  it (there is no on-disk queue). Not the cause here.
- **Pushes straight into Loki.** Entries pushed directly to Loki's API (in order, out of order, with
  identical second-resolution timestamps, with timestamps in the past, with structured metadata) all
  survived an immediate restart, as did entries added to a stream that had already been recovered once.
- **Deletes.** The only processed delete request selects Loki's own query log; the others select test
  streams. None selects nginx.

**Root cause (reproduced on demand, inside Loki).** With default settings Loki keeps new entries in
memory and in a write-ahead log (WAL), and a *checkpoint* of in-memory streams is written periodically.
Recovery after a restart replays the WAL on top of the **last checkpoint** and discards entries it takes to
be already in that checkpoint, using a per-stream counter. A stream that was flushed and re-created after
the checkpoint (an idle stream after 30 minutes, or any stream after a flush) starts counting from 0 again,
so its new entries look like duplicates of checkpointed ones and are **discarded silently** (Loki reports
`errors: false` and counts them as `wal_discarded_samples{reason="duplicate"}`). Two things made the
checkpoint stale: the default interval is 5 minutes **and writing a checkpoint takes about 4.5 minutes**
(measured: `starting checkpoint` 14:20:04, `checkpoint done` 14:24:34), so any restart within about 10
minutes abandons the checkpoint in progress, and the suite and my experiments restarted Loki every few
minutes. Recovery therefore ran from a checkpoint written the previous day.

Reproduction (by construction): flush all streams (`POST /flush`), send 3 warning + 3 info nginx lines
through Alloy, confirm all 6 in Loki, restart Loki. Result before the fix: **0 of 3 and 0 of 3** survived,
50 entries discarded as duplicates. With a fresh checkpoint the same test kept all 6.

**The fix** (all in the Phase 7 Loki configuration and its compose service):

| Setting | Effect |
|---|---|
| `ingester.wal.flush_on_shutdown: true` | On a graceful stop Loki writes every in-memory chunk to storage, so nothing that was in memory depends on WAL replay |
| `ingester.wal.checkpoint_duration: 1m` | A checkpoint now completes about every minute (verified in Loki's log: start :37, done :31 of the next minute) and old WAL segments are truncated (2 segments instead of 16) |
| `stop_grace_period: 30s` (compose) | Gives the shutdown flush time; Docker's default is 10 s |

Verified: the exact failing scenario, repeated three times, kept all 6 lines every time (it lost all
6 before). Loki's recovery still reports "duplicates" discarded (65, 86 and 2 in those runs): the replay
quirk is unchanged, but it no longer matters because the data was already in storage.

### Hard-kill (SIGKILL) limitation: measured

`flush_on_shutdown` cannot run when Loki is killed (crash, out-of-memory kill, `docker kill`), and the
stale-checkpoint behaviour above is an upstream recovery behaviour that no setting removes.

| Scenario | Result |
|---|---|
| SIGKILL in normal operation, 3 runs at different checkpoint phases | **No loss** (6 of 6 lines each time) |
| SIGKILL right after streams were flushed and re-created since the last checkpoint, 3 runs | **Lost in 2 of 3 runs** (the 3 warning lines; 29 entries discarded as duplicates); the third kept everything |

Bound on the risk: it needs (1) a hard kill, (2) within roughly one checkpoint interval (about a minute)
of (3) a stream being re-created, which in normal operation means the first lines after a stream was idle
for 30 minutes (rare streams such as warnings and errors are exactly these). Everything older is safe.
Not tested: abrupt loss of the Docker VM or the host (the WAL is written to the file but not fsynced per
record, so the operating system's unflushed cache is an additional window). The outcome depends on where
the kill falls relative to the checkpoint: a later run of the same hard-kill-after-flush case inside the
suite lost nothing (6 of 6). The suite records the
hard-kill-after-flush case as an `INFO` measurement instead of asserting it, because it is
nondeterministic; it asserts that a hard kill in normal operation loses nothing.

## Using it

Grafana: **Logs (Loki)** dashboard (4th dashboard, folder *Monitoring*) with Service, Level and
Search (regex) variables, volume and severity charts, nginx request panels, per-source log panels and
pipeline health. Or **Explore** -> datasource *Loki*:

```logql
{service="nginx", log_type="access"}                           # all requests
{service="nginx", log_type="access"} | status >= 500            # server errors
{service="backend"} | logger="app.access" | route="/api/v1/tasks/{task_id}"
{job="docker", level=~"error|critical"}                          # all errors
{service="postgres"} |~ "(?i)fatal|authentication"
sum by (level) (count_over_time({job="docker"}[5m]))
quantile_over_time(0.95, {service="nginx", log_type="access"} | json | unwrap request_time [5m]) by (service)
```

## Known limitations

- **Containers that live less than about 10 seconds are not collected.** Discovery polls every 10 s
  (`refresh_interval`); measured: a container that prints 8 lines and exits after 2 s or 8 s yields 0
  lines, one that lives 12 s or more yields all 8. Irrelevant for the long-running services here.
- loki.source.docker does **not** label stdout vs stderr, so nginx's access and error logs are told
  apart by their line shape.
- Alloy reads the logs of any container the proxy lets it see; the project filter is applied by Alloy,
  not enforced by the proxy (see `security.md`).
- Loki has no authentication; it relies on network isolation. Any container on `monitoring`
  (Prometheus, Grafana, Alloy, the proxy) can read, write and delete logs.
- Masking is best-effort pattern matching.
- **A hard kill of Loki can lose the newest lines of a stream that was re-created since the last
  checkpoint** (measured: 2 of 3 runs in that exact condition; no loss in normal operation). See
  "Restart durability" above. Graceful restarts, `docker compose down`/`up`, Loki outages and Alloy
  re-creation are verified lossless.
- Alloy's retry budget is its default (10 retries with exponential backoff). Outages of 20-45 s were
  tested and delivered everything; an outage longer than the retry budget was not tested, and Alloy has
  no on-disk queue, so lines read but not yet delivered would be lost if Alloy itself were killed.
- Single-node, filesystem storage: no replication or backup of the logs.

## Tests

```sh
sh tests/e2e/check_phase7.sh                      # collection, parsing, security, Grafana, regression
PERSISTENCE=0 sh tests/e2e/check_phase7.sh        # skip the restart tests
FULL_CYCLE=1 sh tests/e2e/check_phase7.sh         # + docker compose down/up (NO -v)
python -I tests/e2e/loki_query.py ...             # query helper (through Grafana's datasource proxy)
```

The suite also has a **reliability** section: effective durability settings, restart after a flush (the original
failure condition) twice in a row, a Loki outage with requests during it, Alloy re-created twice with exact
counts (no loss, no duplicates), Alloy's drop counters, a hard kill in normal operation, and a check that
new WAL checkpoints keep completing. The hard-kill-after-flush limitation is printed as `INFO`.

The suite sends a real request through nginx and finds it in Loki (nginx access, nginx error for an
oversized body, backend) with the same `request_id`, runs a masking canary with a positive control, scans
for the four real passwords with a **bracketed regex** (`[a][b][c]`: the literal secret is never sent,
see `security.md`), and checks every proxy refusal.
