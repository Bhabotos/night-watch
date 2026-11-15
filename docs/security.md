# Security Notes

Implementation status: Phases 2-7 are implemented (PostgreSQL, backend, nginx and the UI,
Prometheus and exporters, Grafana, Loki, Alloy and the Docker socket proxy). Sections describe the real,
verified configuration unless they say "planned".

## PostgreSQL (implemented in Phase 2)

- Not published; on the internal `application` network only (shared only with
  the backend and postgres-exporter); no outbound route.
- scram-sha-256 authentication; admin, application and monitoring roles are separate.
- The init script runs **once**, on an empty data volume. If it fails, the entrypoint
  still leaves a half-initialised volume that later starts skip; delete the volume
  (an explicit, destructive step) and start again.
- Secrets are visible to anyone who can run `docker inspect` on the host
  (environment variables); see decisions #29.
- The init script grants PUBLIC no access to the application database.

## Backend (implemented in Phase 3)

- Connects as the non-superuser application role (`APP_DB_USER`); the admin
  credentials are not in its environment, and it refuses to start if its role
  is a superuser. Verified by tests and by inspecting the container.
- On `proxy`, `application` and `metrics` only (all internal): no internet
  egress, no published port. It is the most connected container; a compromise
  reaches nginx, PostgreSQL (as the app role), Prometheus and the exporters.
- Runs as UID 10001, read-only root filesystem (tmpfs `/tmp`), `cap_drop: ALL`,
  `no-new-privileges`, 256 MB / 0.5 CPU.
- Logs: the DB password is redacted from messages and tracebacks; query strings
  are not logged; clients never receive stack traces, SQL or connection detail.
  Verified: neither DB password appears in container logs.
- Metrics: bounded labels (route templates), no task content, identifiers or
  connection details.
- `/health`, `/ready` and `/metrics` are unauthenticated. They are reachable
  by any container on a shared network (see `architecture.md`), and are not
  proxied by nginx as long as nginx forwards only `/api/*`.
- The database password is an environment variable (`docker inspect` shows
  it). See decisions #29.
- No authentication/authorisation on the Tasks API itself: it is a demo
  domain, intended to be reached only through nginx on localhost.

## Frontend / nginx (implemented in Phase 4)

- On `edge` + `proxy` only, never `application`: nginx cannot resolve or open a TCP connection to
  PostgreSQL (verified, with a positive control from the backend). Only nginx publishes a host
  port, bound to `127.0.0.1`; backend and PostgreSQL publish none.
- uid 101, read-only root filesystem (`/tmp` is tmpfs), all capabilities dropped,
  `no-new-privileges`, 128 MB / 0.5 CPU.
- Only `/api/v1/*` is proxied. `/metrics`, `/health`, `/ready` and the OpenAPI docs of the
  backend are not reachable through nginx (verified).
- Headers: strict CSP (`script-src 'self'`, `style-src 'self'`, `frame-ancestors 'none'`),
  `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`, COOP/CORP, no server version.
  The CSP is why the app has no inline styles or scripts.
- Request limits: 64 KB body, 8 KB headers, 10 s header/body timeouts, 30 s proxy timeouts, no
  replay of writes.
- Logs: JSON access log with the request path only (no query string, no `Referer`). **Limitation:**
  nginx's `error_log` (level `warn`) prints the request line, query string included, when it logs
  an error such as an upstream timeout. The app only puts `status`, `limit` and `offset` in query
  strings today. Do not add secrets to URLs. Raising the level to `crit` would hide useful errors.
- The page and API are plain HTTP on localhost and have **no authentication** (not in scope for
  this phase). Do not publish the port on a shared network.
- nginx still has internet egress (it shares `edge` with Grafana); it does not need it.

## Metrics stack (implemented in Phase 5)

- **Prometheus, node-exporter and postgres-exporter** are unpublished, run as `nobody`, with a
  read-only root filesystem, `cap_drop: ALL` and `no-new-privileges`, and sit only on internal
  networks, so none has internet egress (verified). Prometheus has the lifecycle and admin APIs
  disabled (verified: 403 / refused).
- **Reachability:** by topology, the backend can open connections to Prometheus, node-exporter
  and postgres-exporter (shared `metrics` network), and these services have no authentication.
  Anything that compromises the backend can read all metrics. nginx shares no network with them
  (verified). Prometheus cannot reach PostgreSQL (verified); only postgres-exporter and the
  backend can.
- **node-exporter has no host mount.** The common recommendation (bind-mount `/` read-only) was
  tried and **rejected after testing**: on Docker Desktop it let the `nobody` user inside the
  container read the Windows drives (`/mnt/host/c`, `/d`, `/e`), including this project's `.env`.
  Docker's own data directories (`/var/lib/docker`) and `/etc/shadow` were not readable, but the
  Windows files were. With the mount removed (verified: 0 mounts; `/host` and `/mnt/host` do not
  exist in the container) CPU, memory and network metrics are unaffected, and disk usage comes from
  the container's root overlay (the Docker data disk). The cost: no per-mount or Windows-drive disk
  metrics. The earlier mount was live for about 20 minutes during development; the container has
  no internet egress, so nothing could have left the host.
- **Metrics content:** the backend exports route templates and counts only, no user data or
  credentials. Verified: none of the three database passwords appears in any exporter output,
  Prometheus targets or logs.
- **postgres-exporter credentials:** the monitoring role (`pg_monitor`, no superuser, no write
  rights) in an environment variable, over an unencrypted but internal connection.

## Grafana (implemented in Phase 6)

- **First published admin UI.** Login is required (verified: anonymous requests get 401 on the API),
  sign-up is disabled, anonymous access is off, the session cookie is `SameSite=strict`, embedding is
  off. Bound to `127.0.0.1` only; plain HTTP, so do not publish it on a shared network.
- **Admin password** comes from `.env` (required, no default, not in any committed file, not in
  the logs or the settings API: verified). It is an environment variable, so `docker inspect` shows it
  (decision #29). Changing `GRAFANA_ADMIN_PASSWORD` after the first start does **not** change the
  stored admin password (Grafana keeps it in its database); change it in the UI or recreate the
  `grafana_data` volume.
- **What an admin can do:** Explore runs arbitrary PromQL against Prometheus, so a Grafana admin can
  read every metric in the stack. Treat Grafana admin access like Prometheus access. Provisioned
  datasource and dashboards cannot be changed or deleted, but an admin can create new datasources
  and dashboards in the UI (stored in `grafana_data`, outside the repo).
- **Leaks found by probing as an anonymous user and fixed:** Grafana's own `/metrics` was served
  without login (now disabled); `/api/health` and the login page revealed the exact version and
  commit (now masked). Residual: the login page still embeds `grafana_version` in its feature-flag
  context.
- **Network:** Grafana is on `edge` + `monitoring`. It can reach Prometheus (needed) and nothing on
  the data side: PostgreSQL, both exporters and the backend are unreachable from it (verified). Because
  it shares `edge` with nginx, **nginx and Grafana can open connections to each other on any port**
  (not blocked, not needed). Grafana also shares `monitoring` with Prometheus, which has no
  authentication.
- **Egress:** Grafana keeps internet access through `edge` (needed for Phase 8 webhooks) and
  Docker cannot restrict destinations (decision #22). Phoning home is disabled (analytics, update
  checks, plugin install, news feed, snapshots), so today nothing uses that egress.
- **Container:** uid 472, read-only root filesystem, all capabilities dropped, `no-new-privileges`,
  provisioning and dashboard mounts read-only, only `/var/lib/grafana` writable.
- **Dashboards carry no secrets and no user data** (lint-enforced). Metric labels are route
  templates and counts only.

## Docker socket: assessment and design (Phase 7)

Alloy needs the Docker API to discover containers and read their logs. The Docker socket is
effectively root on the engine (on Docker Desktop: root in the Linux VM): whoever can call the API can
start a privileged container, mount the VM filesystem or read every container's environment.
**Mounting the socket `:ro` does not make the API read-only**: it protects the socket *file*, not the
calls made through it.

### Options considered

| Option | Verdict |
|---|---|
| Mount `docker.sock` into Alloy | Rejected: full engine control for a log shipper that parses untrusted log lines |
| Read `json-file` logs through a bind mount of `/var/lib/docker/containers` | Rejected: exposes the logs *and* `config.v2.json` (with environment variables) of **every** container on the machine, needs root, and has no Compose metadata |
| Docker logging driver pushing to Alloy | Rejected: the engine, not a container, connects, so Alloy would need a published host port |
| **Filtering socket proxy between Alloy and the socket** | **Chosen** |

### What is implemented

- **Alloy has no socket mount** and runs as uid 473. Verified: no `docker.sock` in its mounts and the
  path does not exist inside it.
- **Only `docker-socket-proxy` mounts the socket** (read-only, defence in depth only). It is
  `wollomatic/socket-proxy`, a small single-purpose Go binary: non-root (`nobody`, plus group 0
  because Docker Desktop's socket is `root:root 0660`), read-only root filesystem, all capabilities
  dropped, `no-new-privileges`, 32 MB, not published, no internet egress.
- **Allow-list by method and path:** `GET` on `containers/json` (list), `containers/<id>/json`
  (inspect), `containers/<id>/logs`, `networks`, `_ping`, and `HEAD _ping`. Anything unset is denied.
- **Only Alloy may connect** (`-allowfrom=alloy`). Verified: Prometheus and Grafana, which share the
  network, are refused.
- **Verified refusals (every one tested):** `GET` /info, /version, /images/json, /volumes,
  /system/df, /secrets, /swarm, /events and containers/<id>/top, archive, export, changes, stats,
  attach/ws returned 403; `POST` containers/create, exec, start, stop, kill, restart, update,
  images/create, build, volumes/create, networks/create were all refused. The proxy logs each refusal
  (`blocked request` with the reason), and a victim container was not affected.
- Re-creating Alloy (a new IP) does not break the proxy's allow-list (verified).

### Residual risks (not eliminated)

1. **The proxy holds the socket.** If the proxy itself were compromised the attacker gets the Docker
   API. It is tiny, unreachable except from Alloy, and unauthenticated beyond that IP allow-list.
2. **Container inspect is allowed** (Alloy's Docker client needs it) and its response contains every
   container's **environment variables, including secrets** (database passwords, Grafana admin
   password). Alloy's configuration never reads or forwards them (discovery metadata labels carry no
   environment), but a compromised Alloy could read them through the proxy.
3. **Logs of any container on the machine are readable through the proxy**, including other
   projects'. The restriction to this Compose project is applied by Alloy's discovery filter, not
   enforced by the proxy (container ids cannot be allow-listed statically).
4. Alloy and Loki are unauthenticated peers on `monitoring`: a compromised Alloy can write arbitrary
   lines into Loki (and, via the unauthenticated delete API, any `monitoring` member can remove logs).
5. On Linux, the group id of the socket must be set (`DOCKER_SOCKET_GID`); a wrong value either breaks
   log collection or grants the proxy a broader group than needed.

Still suitable for **local and development use**. Before running it on a shared host: keep the proxy
and Alloy images updated, consider per-container allow-listing (the proxy supports it via container
labels, unused here), and restrict who can reach `monitoring`.

## Prometheus UI forwarder (`prometheus-ui`)

The Prometheus web UI is reachable from the Windows host at **http://127.0.0.1:9090** through a minimal TCP
forwarder (`alpine/socat:1.8.1.3`: host `127.0.0.1:9090` -> `prometheus:9090`). Prometheus itself stays
unpublished and attached only to `metrics` and `monitoring`.

- **Why a new network.** Docker cannot publish a host port for a container that is only on `internal: true`
  networks (tested: a forwarder on `monitoring` alone gets no host listener). `edge` was ruled out, so the
  forwarder joins a dedicated non-internal network, `uiaccess`, that contains **only** the forwarder
  (verified), plus `monitoring` to reach Prometheus.
- **Exposure.** Published as `127.0.0.1:9090` only: the Windows listener is exactly `127.0.0.1` (verified, with a
  negative control), never `0.0.0.0`, the LAN or the internet. Any local user or process on this Windows
  machine can open it; there is no authentication.
- **What the UI allows.** Query, graph and browse targets, rules and configuration. The lifecycle and admin APIs
  stay disabled (`/-/reload` returns 403, the snapshot API is refused, verified through the forwarder).
- **The forwarder itself.** Runs as `nobody`, read-only root filesystem, all capabilities dropped,
  `no-new-privileges`, 32 MB, no mounts, no environment, at most 32 concurrent connections, transparent TCP
  (it adds no parsing surface). It has internet egress through `uiaccess` (a non-internal network always does),
  but it holds nothing worth stealing and only forwards to `prometheus:9090`.
- **Network reachability.** nginx and Grafana are not on `uiaccess` and cannot reach the forwarder or Prometheus
  through it (verified for nginx). Prometheus keeps no egress.
- Tests: `tests/e2e/check_prometheus_ui.sh` (20 checks) and the exact-set assertions in
  `check_network_design.sh`, `check_phase6.sh` and `check_phase7.sh`.

## Logs stack (implemented in Phase 7)

- **Loki, Alloy and the proxy** are unpublished, internal-network only (no egress), read-only root
  filesystem, all capabilities dropped, `no-new-privileges`, with CPU and memory limits (verified).
  nginx, the backend, PostgreSQL and the exporters cannot reach any of them (verified).
- **Secrets are masked before storage** by regex in Alloy (passwords, tokens, api keys, SQL
  `PASSWORD '...'`, `Authorization` headers; harmless text is kept). It is defence in depth: the first
  line is that applications do not log secrets. Verified with a canary of six fake secrets and a
  positive control, and by scanning 8 days of stored logs for the four real passwords (0 hits).
- **Labels are low-cardinality** (about 25 streams); per-request values (`request_id`, `path`,
  `status`) are structured metadata. Loki guard rails cap streams, label names, line size and rate.
- **Query strings are never logged** (nginx and the backend); verified end to end in Loki.
- **Log durability (verified, see `loki.md`).** Alloy dropped nothing in any test and retries failed pushes.
  Loki was losing recent lines on restart because its WAL recovery trusted a stale checkpoint; fixed with
  `flush_on_shutdown: true`, 1-minute checkpoints and a 30 s stop grace period (the failing scenario now keeps
  every line). **Residual risk:** a hard kill of Loki (crash, out-of-memory kill, `docker kill`) can still lose
  the newest lines of a stream that was re-created since the last checkpoint (measured: 2 of 3 runs in exactly
  that condition, no loss in normal operation). An attacker or fault that can kill Loki can therefore make the
  last minute of an otherwise quiet stream disappear. Host or VM power loss was not tested.
- **Logs can still contain personal data:** client addresses (the Docker gateway here), user agents
  and request paths. Retention is 7 days.
- **Loki has no authentication.** Network isolation is the control. A Grafana admin can read every
  log line (Explore) just as they can read every metric.
- Grafana's datasource proxy refuses non-allow-listed POSTs to Loki, so Grafana users cannot reach
  Loki's delete endpoint through it. Direct access exists only from containers on `monitoring`.

### A real leak found and fixed during Phase 7

Searching Loki for a secret **stored the secret in Loki.** Loki logs every query it executes
(`executing query`, query statistics) *including the LogQL text*; Alloy collected those lines and
Loki stored them. My own test scripts searched for the four real passwords (to prove they were not in
the logs), and each search wrote that password into Loki's own log, and into the Loki container's Docker
log. The identical hit count for four different passwords (104 each) revealed it. Anyone pasting a
secret into Grafana Explore would have caused the same.

- **Scope:** only Loki's stored data and the Loki container's Docker log file; no other container log
  contained a secret (checked for all four passwords in every container).
- **Fix in the pipeline:** Alloy drops Loki's query-log lines (they stay in `docker logs loki`), which
  also removes a feedback loop (dashboard refreshes generating the logs they display).
- **Remediation:** the stored lines were removed with Loki's delete API (the cancellation window was
  shortened from 24 h to 1 minute for this), and the Loki container was re-created (volume kept) to
  discard its Docker log. Verified afterwards: 0 occurrences of any real password in 8 days of
  stored logs and in every container log.
- **Fix in the tests:** secret scans use a character-class regex (`[a][b][c]`) so the secret never
  appears in a query, with a positive control proving the technique finds unmasked values.
- The secrets were never outside the local machine (internal network, no egress, localhost-only UI).
  The passwords were **not rotated**; if you consider them exposed, rotate them (decision #29 notes
  the database passwords are environment variables).

## Other findings about test methods, fixed

Vacuous checks are a security risk too, because they give false assurance. Corrected in Phase 7: a
masking test that passed on the previous run's leftover lines (now a unique service and marker per
run), a "label values" check that counted the suite's own test containers, a task-preservation check
that required the table to equal my five rows (now a before/after snapshot, so other people's tasks
cannot break it), and check commands that could kill the whole script on failure.

## Network isolation

The design uses six networks: `edge` (external), `uiaccess` (non-internal, only the Prometheus UI
forwarder) and `proxy`, `application`, `metrics`, `monitoring` (all `internal: true`). See `architecture.md` for
membership, reachability and flows.

**Limits you must understand:**

- Docker bridge networks connect all members on all ports in both
  directions. They are **not** directional firewalls. This design does **not**
  provide directional firewall enforcement and does not claim a strict
  allow-list.
- `internal: true` only removes outbound routing; it does not restrict
  traffic between members.
- nginx and PostgreSQL share no network: nginx reaches only the backend (via
  `proxy`) and Grafana (via `edge`). The backend is the only app-tier route
  to PostgreSQL. This is topology, not a firewall: nginx can still reach any
  port on the backend, and the backend any port on nginx. Mitigate by
  proxying only `/api/*` and by keeping `/metrics` out of the nginx config.
- The backend is on `proxy`, `application` and `metrics` and is the most
  connected container. It has no internet egress and no route to Grafana,
  Loki or Alloy, but a compromised backend reaches nginx, PostgreSQL (with
  the app role's credentials), Prometheus and the exporters.
- Services that bridge networks (Prometheus, Grafana, backend,
  postgres-exporter, nginx) are lateral-movement points if compromised.
- Loki, Alloy, node-exporter, postgres-exporter and (by default) Prometheus
  have no authentication. Anything on a shared network can query them.
  Phase 9 will reduce this with authentication where practical and by
  disabling Prometheus admin/lifecycle APIs.

### Grafana webhook egress

Grafana is the only observability component with internet access (via
`edge`), needed for alert delivery.

- Required: outbound HTTPS 443 (or SMTP 587) to the configured contact point,
  plus DNS.
- Not restricted: Docker cannot limit destinations, so Grafana (and nginx)
  can reach any internet host. Exfiltration from a compromised Grafana is
  possible. Restricting it requires a host firewall or an egress proxy, neither
  of which is planned for local use.
- Grafana analytics, update checks and plugin installs are disabled to keep
  egress purpose-limited.
- Webhook URLs and tokens are secrets: supplied via `.env`, never committed.

### Windows / Docker Desktop

- Containers and the Docker socket live inside the Docker Desktop Linux VM.
  Host `DOCKER-USER` iptables rules are not practically available, so strict
  egress filtering is not feasible there.
- Published ports bind to `127.0.0.1` and are forwarded to the Windows
  loopback; they are not reachable from the LAN.
- node-exporter reports VM metrics, not Windows metrics.

## Other controls (planned)

- Secrets only via `.env` (gitignored, in place); Compose fails fast if unset.
- PostgreSQL never publishes a port; it sits on an internal network and has
  no outbound route.
- Only nginx (default 8088), Grafana (default 3001) and the Prometheus UI forwarder (9090) publish ports, all bound
  to `127.0.0.1`. Prometheus itself, Loki, Alloy, the exporters and PostgreSQL are never published.
- Containers run as non-root with `no-new-privileges` where supported.
- postgres-exporter uses a dedicated least-privilege monitoring role, not the
  application user or a superuser.
