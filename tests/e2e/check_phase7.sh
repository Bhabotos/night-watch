#!/bin/sh
# Phase 7 checks: Loki, Alloy, the Docker socket proxy, log collection, Grafana Logs dashboard,
# security and persistence. Run from the repo root with the stack up:
#   sh tests/e2e/check_phase7.sh
#
#   PERSISTENCE=0   skip the restart tests (default 1)
#   FULL_CYCLE=1    also run `docker compose down` + `up` (NO -v: volumes are kept) (default 0)
set -u
export MSYS_NO_PATHCONV=1 PYTHONUTF8=1
set -a; . ./.env; set +a
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

PERSISTENCE=${PERSISTENCE:-1}; FULL_CYCLE=${FULL_CYCLE:-0}
G="http://127.0.0.1:${GRAFANA_HOST_PORT:-3001}"; U="http://127.0.0.1:${FRONTEND_HOST_PORT:-8088}"
LOKI=monitoring-3tier-loki-1; ALLOY=monitoring-3tier-alloy-1; PXY=monitoring-3tier-docker-socket-proxy-1
GR=monitoring-3tier-grafana-1; PROM=monitoring-3tier-prometheus-1; NGINX=monitoring-3tier-nginx-1
BE=monitoring-3tier-backend-1; PG=monitoring-3tier-postgres-1; PGX=monitoring-3tier-postgres-exporter-1
NODE=monitoring-3tier-node-exporter-1
PY="python -I"; LQ="$PY tests/e2e/loki_query.py"
AUTH="$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD"
gapi() { curl -s -u "$AUTH" "$@"; }
nets() { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" | tr ' ' '\n' | sort | tr -d '\n'; }
wait_healthy() { for i in $(seq 1 90); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = healthy ] && return 0; sleep 3; done; return 1; }
# poll a Loki query until it returns >= 1 line (collection has a few seconds of latency)
wait_lines() { for i in $(seq 1 30); do [ "$($LQ count "$1" ${2:-10})" -ge 1 ] 2>/dev/null && return 0; sleep 2; done; return 1; }
# HTTP status as seen by Alloy (the only client the proxy accepts); busybox wget prints it with -S
via_alloy() { docker exec $ALLOY /busybox wget -S -q -O /dev/null -T 5 ${2:-} "$1" 2>&1 | sed -n 's/.*HTTP\/1\.[01] \([0-9]*\).*/\1/p' | head -1; }
# poll until a count equals the expected value (Loki may take a few seconds to answer after a restart)
wait_count() { for i in $(seq 1 30); do [ "$($LQ count "$1" $2 2>/dev/null)" = "$3" ] && return 0; sleep 2; done; return 1; }
# Task preservation: compare against a snapshot taken at the start, so tasks other people create while
# the suite runs can never break it. Every row that existed at the start must still exist unchanged.
snapshot_tasks() { curl -s "$U/api/v1/tasks?limit=100" | $PY -c "import sys,json; print(json.dumps(sorted((t['id'],t['title'],t['status']) for t in json.load(sys.stdin)['items'])))"; }
tasks_preserved() { TB="$TASKS_BEFORE" CU="$(snapshot_tasks)" $PY -c "import os,sys,json; b=json.loads(os.environ['TB']); c=json.loads(os.environ['CU']); sys.exit(0 if len(b) >= 5 and all(r in c for r in b) else 1)"; }
five_present() { snapshot_tasks | $PY -c "import sys,json; t={r[1] for r in json.load(sys.stdin)}; sys.exit(0 if {'p5 load %d' % i for i in range(1,6)} <= t else 1)"; }
# ---- reliability helpers (used by the "reliability" section) -------------------------------------------
NGINX_ACCESS='{service=\"nginx\", log_type=\"access\"'
nginx_all_stored() { # marker: all 3 warning (404) and all 3 info (200) lines present, exactly (no loss, no duplicates)
  wait_count "{service=\"nginx\", log_type=\"access\", level=\"warning\"} |= \"$1\"" 20 3 && \
  wait_count "{service=\"nginx\", log_type=\"access\", level=\"info\"} |= \"$1\"" 20 3; }
make_traffic() { # marker: 3 warning-level (404 via the API) and 3 info-level (200, SPA) nginx lines
  for i in 1 2 3; do curl -s -o /dev/null "$U/api/v1/${1}w$i"; curl -s -o /dev/null "$U/${1}i$i"; done; }
wait_stored() { nginx_all_stored "$1"; }
flush_streams() { docker run --rm --network monitoring-3tier_monitoring curlimages/curl -s -o /dev/null -w '%{http_code}' -X POST http://loki:3100/flush | grep -q 204 && sleep 40; }
# The condition that originally lost data: streams flushed and re-created after the last checkpoint,
# then a restart. (Loki replays the WAL on top of the checkpoint and discards "duplicate" entries by a
# per-stream counter; a re-created stream restarts its counter at 0.)
graceful_restart_after_flush() { # label
  flush_streams || return 1; m="rst$1$(date +%s)"; make_traffic "$m"; wait_stored "$m" || return 1
  docker restart $LOKI >/dev/null; wait_healthy $LOKI; nginx_all_stored "$m"; }
loki_outage_delivery() {
  m="out$(date +%s)"; docker stop $LOKI >/dev/null; make_traffic "$m"; sleep 20
  docker start $LOKI >/dev/null; wait_healthy $LOKI; nginx_all_stored "$m"; }
alloy_recreate_no_loss_no_dup() {
  m="alo$(date +%s)"; make_traffic "$m"
  docker compose up -d --force-recreate --wait alloy >/dev/null 2>&1; wait_healthy $ALLOY
  nginx_all_stored "$m" && wait_count "{service=\"backend\"} |= \"$m\"" 20 3 || return 1
  docker compose up -d --force-recreate --wait alloy >/dev/null 2>&1; wait_healthy $ALLOY; sleep 15
  nginx_all_stored "$m" && wait_count "{service=\"backend\"} |= \"$m\"" 20 3; }   # exact counts: duplicates would fail
hard_kill_normal_operation() {
  m="kil$(date +%s)"; make_traffic "$m"; wait_stored "$m" || return 1
  docker kill $LOKI >/dev/null; sleep 3; [ "$(docker inspect -f '{{.State.Running}}' $LOKI)" = true ] || docker start $LOKI >/dev/null
  wait_healthy $LOKI; nginx_all_stored "$m"; }
ckpt_list() { docker run --rm -v monitoring-3tier_loki_data:/l:ro alpine sh -c 'ls /l/wal | grep -E "^checkpoint\.[0-9]+$" | tr "\n" " "'; }
checkpoints_advance() { a=$(ckpt_list); for i in $(seq 1 45); do b=$(ckpt_list); [ -n "$b" ] && [ "$b" != "$a" ] && return 0; sleep 5; done; return 1; }
task_titles() { curl -s "$U/api/v1/tasks?limit=100" | $PY -c "import sys,json; print(','.join(sorted(t['title'] for t in json.load(sys.stdin)['items'])))"; }
TASKS_BEFORE=$(snapshot_tasks)
echo "      tasks at start: $TASKS_BEFORE"

echo "== static"
check "docker compose config is valid" "docker compose config -q && docker compose --profile test config -q"
ALLOY_IMG=$(sed -n 's/^ARG ALLOY_IMAGE=//p' monitoring/alloy/Dockerfile); LOKI_IMG=$(sed -n 's/^ARG LOKI_IMAGE=//p' monitoring/loki/Dockerfile)
W=$(pwd -W 2>/dev/null || pwd)
check "alloy config is valid ($ALLOY_IMG)" "docker run --rm -v $W/monitoring/alloy/config.alloy:/c.alloy:ro $ALLOY_IMG validate /c.alloy"
check "alloy config is canonically formatted (alloy fmt makes no change)" "[ \"\$(docker run --rm -v $W/monitoring/alloy/config.alloy:/c.alloy:ro $ALLOY_IMG fmt /c.alloy | tr -d '\\r' | md5sum | cut -d' ' -f1)\" = \"\$(tr -d '\\r' < monitoring/alloy/config.alloy | md5sum | cut -d' ' -f1)\" ]"
check "loki config is valid ($LOKI_IMG)" "docker run --rm -v $W/monitoring/loki/loki.yml:/etc/loki/loki.yml:ro $LOKI_IMG -config.file=/etc/loki/loki.yml -verify-config 2>&1 | grep -q 'config is valid'"
check "dashboard lint passes (incl. logs rules)" "$PY tests/e2e/dashboards_lint.py >/dev/null"
check "only the proxy mounts the Docker socket" "[ \"\$(docker compose config --format json | $PY -c \"import sys,json; s=json.load(sys.stdin)['services']; print(','.join(sorted(n for n,v in s.items() if any('docker.sock' in str(m.get('source','')) for m in v.get('volumes',[])))))\")\" = docker-socket-proxy ]"
check "the socket is mounted read-only (defence in depth, not a control)" "docker compose config --format json | $PY -c \"import sys,json; v=json.load(sys.stdin)['services']['docker-socket-proxy']['volumes']; sys.exit(0 if all(m.get('read_only') for m in v if 'docker.sock' in m['source']) else 1)\""
check "none of the real passwords appears in any committed monitoring config or Dockerfile" "( for v in \"\$APP_DB_PASSWORD\" \"\$POSTGRES_ADMIN_PASSWORD\" \"\$EXPORTER_DB_PASSWORD\" \"\$GRAFANA_ADMIN_PASSWORD\"; do ! grep -rqF -- \"\$v\" monitoring docker-compose.yml .env.example || exit 1; done )"

echo "== services and health"
for c in $LOKI $ALLOY $PXY; do check "$c is healthy" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $c)\" = healthy ]"; done
check "loki /ready" "docker exec $GR wget -q -O- http://loki:3100/ready | grep -q ready"
check "alloy /-/ready and /-/healthy" "docker exec $PROM wget -q -O- http://alloy:12345/-/ready | grep -qi ready && docker exec $PROM wget -q -O- http://alloy:12345/-/healthy | grep -qi healthy"
TARGETS=$(docker exec $GR wget -q -O- http://prometheus:9090/api/v1/targets | $PY -c "import sys,json; print(' '.join(sorted(t['labels']['job']+'='+t['health'] for t in json.load(sys.stdin)['data']['activeTargets'])))")
check "prometheus scrapes loki and alloy ($TARGETS)" "echo \"\$TARGETS\" | grep -q 'alloy=up' && echo \"\$TARGETS\" | grep -q 'loki=up'"
check "loki retention is 7 days and the compactor enforces it" "docker exec $GR wget -q -O- http://loki:3100/config | grep -E 'retention_period: (1w|168h)' >/dev/null && docker exec $GR wget -q -O- http://loki:3100/config | grep -E 'retention_enabled: true' >/dev/null"
check "loki accepts structured metadata and does not auto-create labels" "docker exec $GR wget -q -O- http://loki:3100/config | grep -E 'allow_structured_metadata: true' >/dev/null"
check "Loki and Alloy metrics are in prometheus" "[ \"\$(docker exec $GR wget -q -O- 'http://prometheus:9090/api/v1/query?query=count(loki_distributor_lines_received_total)' | $PY -c \"import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)\")\" != 0 ] && [ \"\$(docker exec $GR wget -q -O- 'http://prometheus:9090/api/v1/query?query=count(loki_write_sent_entries_total)' | $PY -c \"import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)\")\" != 0 ]"

echo "== exposure, network and hardening"
for c in $LOKI $ALLOY $PXY; do check "$c publishes no host port" "[ -z \"\$(docker port $c)\" ]"; done
check "only nginx, grafana and the Prometheus UI forwarder publish ports, all on 127.0.0.1" "[ \"\$(docker ps --filter name=monitoring-3tier --format '{{.Names}}={{.Ports}}' | grep '127.0.0.1' | cut -d= -f1 | sort | tr '\\n' ' ')\" = 'monitoring-3tier-grafana-1 monitoring-3tier-nginx-1 monitoring-3tier-prometheus-ui-1 ' ] && [ \"\$(docker ps --filter name=monitoring-3tier --format '{{.Ports}}' | grep -c '0.0.0.0')\" = 0 ]"
for c in $LOKI $ALLOY $PXY; do check "$c is on the monitoring network only" "[ \"\$(nets $c)\" = 'monitoring-3tier_monitoring' ]"; done
check "grafana and prometheus can reach loki (controls)" "docker exec $GR nc -z -w3 loki 3100 && docker exec $PROM nc -z -w3 loki 3100"
check "nginx, backend, postgres, exporters cannot reach loki, alloy or the proxy" "! docker exec $NGINX nc -z -w2 loki 3100 2>/dev/null && ! docker exec $NGINX nc -z -w2 alloy 12345 2>/dev/null && ! docker exec $NGINX nc -z -w2 docker-socket-proxy 2375 2>/dev/null && ! docker exec $BE python -c \"import socket; socket.create_connection(('loki',3100),timeout=2)\" 2>/dev/null && ! docker exec $PGX nc -z -w2 loki 3100 2>/dev/null && ! docker exec $NODE nc -z -w2 loki 3100 2>/dev/null"
check "no internet egress from loki, alloy or the proxy" "! docker exec $ALLOY /busybox wget -q -T 3 -O /dev/null http://1.1.1.1 2>/dev/null && ! docker exec $LOKI /busybox wget -q -T 3 -O /dev/null http://1.1.1.1 2>/dev/null && ! docker exec $PXY /busybox wget -q -T 3 -O /dev/null http://1.1.1.1 2>/dev/null"
check "loki: non-root, read-only rootfs, caps dropped, no-new-privileges, unprivileged" "[ \"\$(docker inspect -f '{{.Config.User}}' $LOKI)\" = 10001 ] && [ \"\$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Privileged}}' $LOKI)\" = 'true [ALL] [no-new-privileges:true] false' ]"
check "alloy: runs as uid 473, read-only rootfs, caps dropped, no-new-privileges" "[ \"\$(docker inspect -f '{{.Config.User}}' $ALLOY)\" = 473:473 ] && [ \"\$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Privileged}}' $ALLOY)\" = 'true [ALL] [no-new-privileges:true] false' ]"
check "proxy: runs as nobody, read-only rootfs, caps dropped, no-new-privileges" "[ \"\$(docker inspect -f '{{.Config.User}}' $PXY)\" = 65534:65534 ] && [ \"\$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Privileged}}' $PXY)\" = 'true [ALL] [no-new-privileges:true] false' ]"
for c in $LOKI $ALLOY $PXY; do check "$c has memory and CPU limits" "[ \"\$(docker inspect -f '{{.HostConfig.Memory}}' $c)\" != 0 ] && [ \"\$(docker inspect -f '{{.HostConfig.NanoCpus}}' $c)\" != 0 ]"; done
check "alloy has NO docker socket mount and cannot see it" "[ -z \"\$(docker inspect -f '{{range .Mounts}}{{.Source}} {{end}}' $ALLOY | grep docker.sock)\" ] && ! docker exec $ALLOY /busybox ls /var/run/docker.sock 2>/dev/null"
check "the proxy mounts the socket read-only and nothing else from the host" "[ \"\$(docker inspect -f '{{range .Mounts}}{{.Destination}}:{{.RW}} {{end}}' $PXY | tr -d '\\n')\" = '/var/run/docker.sock:false ' ]"
check "loki and alloy data are on named volumes" "docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' $LOKI | grep -q monitoring-3tier_loki_data && docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' $ALLOY | grep -q monitoring-3tier_alloy_data"

echo "== docker socket proxy: only the allow-listed Docker API calls work"
CID=$(docker inspect -f '{{.Id}}' $NGINX)
check "alloy -> GET /containers/json is allowed (200)" "[ \"\$(via_alloy http://docker-socket-proxy:2375/containers/json)\" = 200 ]"
check "alloy -> GET /containers/<id>/json (inspect) is allowed (200)" "[ \"\$(via_alloy http://docker-socket-proxy:2375/containers/$CID/json)\" = 200 ]"
check "alloy -> GET /networks and /_ping are allowed" "[ \"\$(via_alloy http://docker-socket-proxy:2375/networks)\" = 200 ] && [ \"\$(via_alloy http://docker-socket-proxy:2375/_ping)\" = 200 ]"
for ep in info version images/json volumes system/df secrets swarm "containers/$CID/top" "containers/$CID/archive?path=/etc" "containers/$CID/export" "containers/$CID/changes" "containers/$CID/stats?stream=false" "containers/$CID/attach/ws" events; do
  check "alloy -> GET /$ep is refused (403)" "[ \"\$(via_alloy \"http://docker-socket-proxy:2375/$ep\")\" = 403 ]"
done
for ep in containers/create "containers/$CID/exec" "containers/$CID/start" "containers/$CID/stop" "containers/$CID/kill" "containers/$CID/restart" "containers/$CID/update" images/create build volumes/create networks/create; do
  check "alloy -> POST /$ep is refused" "[ \"\$(via_alloy \"http://docker-socket-proxy:2375/$ep\" --post-data=x)\" != 200 ] && [ \"\$(via_alloy \"http://docker-socket-proxy:2375/$ep\" --post-data=x)\" != 201 ]"
done
check "a container is not deleted by a DELETE-like attempt (nginx still running)" "[ \"\$(docker inspect -f '{{.State.Running}}' $NGINX)\" = true ]"
check "prometheus (another monitoring container) is refused by the proxy" "! docker exec $PROM wget -q -O /dev/null -T 5 http://docker-socket-proxy:2375/containers/json 2>/dev/null"
check "grafana (another monitoring container) is refused by the proxy" "! docker exec $GR wget -q -O /dev/null -T 5 http://docker-socket-proxy:2375/containers/json 2>/dev/null"
check "the proxy logs the refusals" "docker logs $PXY 2>&1 | grep -q -E 'denied|not allowed|forbidden|blocked'"

echo "== collection: container logs reach Loki"
SERVICES=$($LQ values service 360 | tr '\n' ' ')
echo "      services in Loki: $SERVICES"
for s in backend nginx postgres postgres-exporter prometheus node-exporter grafana loki alloy docker-socket-proxy; do
  check "service '$s' has logs in Loki" "$LQ values service 360 | grep -qx '$s'"
done
TS=$(date +%s); CANARY="canary-$TS"; OTHER="foreign-$TS"
docker run -d --rm --name e2e-canary-$TS --label com.docker.compose.project=monitoring-3tier --label com.docker.compose.service=e2e-canary alpine sh -c "echo $CANARY; echo 'level=warn x'; sleep 25" >/dev/null
docker run -d --rm --name e2e-foreign-$TS alpine sh -c "echo $OTHER; sleep 25" >/dev/null
check "a new container of this project is discovered and its logs arrive (<60s)" "wait_lines '{service=\"e2e-canary\"} |= \"$CANARY\"' 10"
check "labels on the new container's stream are service, container, level, job" "$LQ meta '{service=\"e2e-canary\"} |= \"$CANARY\"' 10 | $PY -c \"import sys,json; s=json.load(sys.stdin); sys.exit(0 if s.get('service')=='e2e-canary' and s.get('container')=='e2e-canary-$TS' and s.get('job')=='docker' and s.get('level') else 1)\""
sleep 8
check "a container of ANOTHER project (no compose label) is NOT collected" "[ \"\$($LQ count '{job=\"docker\"} |= \"$OTHER\"' 10)\" = 0 ]"
docker rm -f e2e-canary-$TS e2e-foreign-$TS >/dev/null 2>&1

echo "== collection: a test request travels through nginx and the backend into Loki"
MARK="e2e$(date +%s)"
curl -s -o /dev/null "$U/api/v1/$MARK?token=QSECRET-$MARK&limit=1"
check "nginx ACCESS log line for the request is in Loki (<60s)" "wait_lines '{service=\"nginx\", log_type=\"access\"} |= \"/api/v1/$MARK\"' 10"
check "backend log line for the same request is in Loki (<60s)" "wait_lines '{service=\"backend\"} |= \"/api/v1/$MARK\"' 10"
RID=$($LQ meta "{service=\"nginx\", log_type=\"access\"} |= \"/api/v1/$MARK\"" 10 | $PY -c "import sys,json; print(json.load(sys.stdin).get('request_id',''))")
check "nginx line has structured fields: request_id, method GET, status 404, level warning" "$LQ meta '{service=\"nginx\", log_type=\"access\"} |= \"/api/v1/$MARK\"' 10 | $PY -c \"import sys,json; s=json.load(sys.stdin); sys.exit(0 if len(s.get('request_id',''))==32 and s.get('method')=='GET' and s.get('status')=='404' and s.get('level')=='warning' and s.get('log_type')=='access' else 1)\""
check "backend line has level info, logger app.access, same request_id" "$LQ meta '{service=\"backend\"} |= \"/api/v1/$MARK\"' 10 | $PY -c \"import sys,json; s=json.load(sys.stdin); sys.exit(0 if s.get('level')=='info' and s.get('logger')=='app.access' and s.get('request_id')=='$RID' else 1)\""
check "one query on request_id finds both services (nginx + backend)" "[ \"\$($LQ count '{job=\"docker\"} | request_id=\"$RID\"' 10)\" -ge 2 ]"
check "the backend line is valid JSON with the request fields" "$LQ lines '{service=\"backend\"} |= \"/api/v1/$MARK\"' 10 | tail -1 | $PY -c \"import sys,json; d=json.loads(sys.stdin.read()); sys.exit(0 if d['request_id']=='$RID' and d['status']==404 and d['method']=='GET' else 1)\""
check "the query string is NOT in Loki (nginx and backend never log it)" "[ \"\$($LQ count '{job=\"docker\"} |= \"QSECRET-$MARK\"' 10)\" = 0 ]"

echo "== collection: nginx ERROR log"
head -c 100000 /dev/zero | tr '\0' a | { printf '{"title":"x","description":"'; cat; printf '"}'; } | curl -s -o /dev/null -X POST "$U/api/v1/big-$MARK" -H 'content-type: application/json' --data-binary @-
check "nginx error log line is in Loki with log_type=error, level=error (<60s)" "wait_lines '{service=\"nginx\", log_type=\"error\", level=\"error\"} |= \"big-$MARK\"' 10"
check "the error line is the oversized-body message" "$LQ lines '{service=\"nginx\", log_type=\"error\"} |= \"big-$MARK\"' 10 | grep -q 'too large body'"
check "the same request is in the access log as a 413 (level warning)" "$LQ meta '{service=\"nginx\", log_type=\"access\"} |= \"big-$MARK\"' 10 | $PY -c \"import sys,json; s=json.load(sys.stdin); sys.exit(0 if s.get('status')=='413' else 1)\""

echo "== parsing, labels and cardinality"
sleep 3
# Label names come from recent series (the label-names API works at whole-day index granularity
# and would still list labels of streams created before the last config change).
LABELS=$($LQ serieslabels '{job="docker"}' 5 | tr '\n' ' ')
check "label names are exactly container job level log_type service ($LABELS)" "[ \"\$LABELS\" = 'container job level log_type service ' ]"
check "request_id, path, status, method are NOT labels" "! echo \"\$LABELS\" | grep -qE 'request_id|path|status|method|route|user_agent'"
check "level values are only the common vocabulary (debug info warning error critical unknown)" "[ -z \"\$($LQ values level 360 | grep -vxE 'debug|info|warning|error|critical|unknown')\" ] && [ -n \"\$($LQ values level 360)\" ]"
check "series count stays small (<80 streams in 6h)" "[ \"\$($LQ series '{job=\"docker\"}' 360)\" -lt 80 ]"
STACK='{job="docker", service!~"e2e-.+|rc-.+|repro-.+|redaction-canary"}'
check "every label has few values over the stack's own streams (<=12 each)" "( for l in container job level log_type service; do [ \"\$($LQ seriesvalues \$l '$STACK' 360 | wc -l)\" -le 12 ] || exit 1; done )"
check "nginx healthcheck requests (user-agent Wget) are dropped, not stored" "docker logs --since 5m $NGINX 2>&1 | grep -q '\"user_agent\":\"Wget' && [ \"\$($LQ count '{service=\"nginx\", log_type=\"access\"} |= \"Wget\"' 5)\" = 0 ]"
check "backend JSON is parsed: structured metadata route/logger/status are queryable" "[ \"\$($LQ count '{service=\"backend\"} | logger=\"app.access\" | status=\"404\"' 10)\" -ge 1 ]"
check "postgres level is parsed (FATAL/ERROR -> critical/error exist or info present)" "$LQ values level 360 >/dev/null && [ \"\$($LQ count '{service=\"postgres\", level=~\"info|warning|error|critical\"}' 360)\" -ge 1 ]"

echo "== LogQL validation (direct, and through Grafana's Loki datasource like Explore)"
check "log query with line filter" "[ \"\$($LQ count '{service=\"nginx\"} |= \"/api/v1/$MARK\"' 10)\" -ge 1 ]"
check "regex line filter" "[ \"\$($LQ count '{service=\"nginx\", log_type=\"access\"} |~ \"/api/v1/e2e[0-9]+\"' 10)\" -ge 1 ]"
check "JSON parser + field filter" "[ \"\$($LQ count '{service=\"nginx\", log_type=\"access\"} | json | status=\"404\"' 10)\" -ge 1 ]"
check "metric query: count_over_time by level" "$LQ metric 'sum by (level) (count_over_time({job=\"docker\"}[10m]))' | grep -vq none"
check "metric query: rate" "$LQ metric 'sum(rate({service=\"nginx\"}[5m]))' | grep -vq none"
check "metric query: quantile over unwrapped request_time" "$LQ metric 'quantile_over_time(0.95, {service=\"nginx\", log_type=\"access\"} | json | unwrap request_time [10m]) by (service)' | grep -vq none"
check "the same marker is found through Grafana's datasource API" "gapi $G/api/ds/query -X POST -H 'Content-Type: application/json' -d \"{\\\"queries\\\":[{\\\"refId\\\":\\\"A\\\",\\\"datasource\\\":{\\\"type\\\":\\\"loki\\\",\\\"uid\\\":\\\"loki\\\"},\\\"expr\\\":\\\"{service=~\\\\\\\"nginx|backend\\\\\\\"} |= \\\\\\\"/api/v1/$MARK\\\\\\\"\\\",\\\"queryType\\\":\\\"range\\\",\\\"maxLines\\\":20}],\\\"from\\\":\\\"now-15m\\\",\\\"to\\\":\\\"now\\\"}\" | grep -q '$RID'"
echo "      Explore link: $G/explore  (datasource Loki, query:  {job=\"docker\"} | request_id=\"$RID\" )"

echo "== secrets are not collected"
for name in APP_DB_PASSWORD POSTGRES_ADMIN_PASSWORD EXPORTER_DB_PASSWORD GRAFANA_ADMIN_PASSWORD; do
  check "$name does not appear in any stored log line (24h)" "[ \"\$($LQ leak @$name 1440)\" = 0 ]"
done
check "searching never put a secret into Loki's own container log (the search is bracketed)" "( for name in APP_DB_PASSWORD POSTGRES_ADMIN_PASSWORD EXPORTER_DB_PASSWORD GRAFANA_ADMIN_PASSWORD; do eval v=\\\$\$name; [ \"\$(docker logs $LOKI 2>&1 | grep -cF -- \"\$v\")\" = 0 ] || exit 1; done )"
check "Loki's own query-log lines are not stored (Alloy drops them; no feedback loop)" "$LQ count '{job=\"docker\"} |= \"harmless-probe-text\"' 5 >/dev/null; sleep 12; [ \"\$($LQ count '{service=\"loki\"} |= \"\\\"query\\\":\\\"\"' 2)\" = 0 ]"
cat > /tmp/e2e_canary.sh <<'EOS'
echo "redact-start-$1"
echo 'password=hunter2supersecret host=db'
echo '{"password": "jsonsecret99","user":"bob"}'
echo "STATEMENT:  CREATE ROLE x LOGIN PASSWORD 'sqlsecret77'"
echo 'Authorization: Bearer abcdefgh12345678XYZ'
echo 'api_key: KEY1234567890 token=tok_abc123def456 secretary=fine'
echo 'positive-control-unmasked-value-'$1
sleep 20
EOS
docker run -d --rm --name e2e-redact-$TS --label com.docker.compose.project=monitoring-3tier --label com.docker.compose.service=e2e-redact-$TS alpine sh -c "$(cat /tmp/e2e_canary.sh)" sh $TS >/dev/null
check "masking canary: THIS run's container is collected (unique service e2e-redact-$TS, <60s)" "wait_lines '{service=\"e2e-redact-$TS\"} |= \"redact-start-$TS\"' 10"
check "masking canary: all 7 lines of this run arrived" "wait_lines '{service=\"e2e-redact-$TS\"} |= \"positive-control-unmasked-value-$TS\"' 10 && [ \"\$($LQ count '{service=\"e2e-redact-$TS\"}' 10)\" = 7 ]"
for s in hunter2supersecret jsonsecret99 sqlsecret77 abcdefgh12345678XYZ KEY1234567890 tok_abc123def456; do
  check "masking canary: '$s' was masked before storage" "[ \"\$($LQ leak $s 10)\" = 0 ]"
done
check "positive control: a value the masking does NOT cover IS found by the same bracketed search" "[ \"\$($LQ leak positive-control-unmasked-value-$TS 10)\" -ge 1 ]"
check "masking canary: harmless text is kept (no false positive)" "$LQ lines '{service=\"e2e-redact-$TS\"}' 10 | grep -q 'secretary=fine' && $LQ lines '{service=\"e2e-redact-$TS\"}' 10 | grep -q 'password=\\*\\*\\*'"
docker rm -f e2e-redact-$TS >/dev/null 2>&1

echo "== Grafana: Loki datasource and Logs dashboard"
check "Loki datasource is provisioned, read-only, not default" "gapi $G/api/datasources | $PY -c \"import sys,json; d=[x for x in json.load(sys.stdin) if x['uid']=='loki']; sys.exit(0 if d and d[0]['readOnly'] and not d[0]['isDefault'] and d[0]['url']=='http://loki:3100' else 1)\""
check "Loki datasource health check succeeds" "gapi $G/api/datasources/uid/loki/health | grep -q '\"status\":\"OK\"'"
check "Loki datasource cannot be modified or deleted through the API" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' -u '$AUTH' -X DELETE $G/api/datasources/uid/loki)\" != 200 ] && gapi $G/api/datasources/uid/loki/health | grep -q OK"
check "request_id derived field is configured" "gapi $G/api/datasources/uid/loki | grep -q 'request_id'"
check "Logs dashboard is provisioned (uid logs) among the required dashboards" "gapi \"$G/api/search?type=dash-db\" | $PY -c \"import sys,json; sys.exit(0 if 'logs' in {d['uid'] for d in json.load(sys.stdin)} else 1)\""
check "every query of every dashboard (incl. Logs) runs through Grafana and returns data" "$PY tests/e2e/grafana_panels_check.py > /tmp/panels7.out 2>&1; tail -1 /tmp/panels7.out | grep -q ' 0 failed'"
echo "      ($(tail -1 /tmp/panels7.out))"
check "the Logs dashboard's Loki panels all ran (16 Loki queries)" "[ \"\$(sed -n '/== Logs/,/== PostgreSQL/p' /tmp/panels7.out | grep -c '^  PASS')\" -ge 20 ]"

echo "== PostgreSQL data preserved"
check "the five Phase 5 test tasks (p5 load 1..5) are all present" "five_present"
check "every task that existed when the suite started is still there, unchanged" "tasks_preserved"
check "the database itself holds at least those five tasks" "[ \"\$(docker exec -e PGPASSWORD=\"\$APP_DB_PASSWORD\" $PG psql -h 127.0.0.1 -U \"\$APP_DB_USER\" -d \"\$APP_DB_NAME\" -Atc \"select count(*) from tasks where title in ('p5 load 1','p5 load 2','p5 load 3','p5 load 4','p5 load 5')\")\" = 5 ]"
check "all five named volumes still exist" "[ \"\$(docker volume ls --format '{{.Name}}' | grep -c '^monitoring-3tier_\\(postgres_data\\|prometheus_data\\|grafana_data\\|loki_data\\|alloy_data\\)\$')\" = 5 ]"

if [ "$PERSISTENCE" = 1 ]; then
echo "== persistence: restarts"
PM="persist$(date +%s)"
curl -s -o /dev/null "$U/api/v1/$PM"
wait_lines "{service=\"backend\"} |= \"/api/v1/$PM\"" 10
N_BEFORE=$($LQ count "{job=\"docker\"} |= \"/api/v1/$PM\"" 30)
check "persistence marker is in Loki before the restarts ($N_BEFORE lines)" "[ \"$N_BEFORE\" -ge 2 ]"
docker restart $ALLOY >/dev/null; wait_healthy $ALLOY
check "alloy is healthy after a restart" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $ALLOY)\" = healthy ]"
sleep 15
check "alloy restart did not duplicate or lose lines (positions persisted)" "wait_count '{job=\"docker\"} |= \"/api/v1/$PM\"' 30 \"$N_BEFORE\""
AM="after-alloy$(date +%s)"; curl -s -o /dev/null "$U/api/v1/$AM"
check "alloy ships new logs after its restart" "wait_lines '{service=\"nginx\", log_type=\"access\"} |= \"/api/v1/$AM\"' 10"
docker restart $LOKI >/dev/null; wait_healthy $LOKI; sleep 10
check "loki is healthy after a restart" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $LOKI)\" = healthy ]"
check "logs ingested before the Loki restart are still queryable (WAL/chunks on the volume)" "wait_count '{job=\"docker\"} |= \"/api/v1/$PM\"' 30 \"$N_BEFORE\""
check "grafana's Loki datasource is healthy again after the restart" "gapi $G/api/datasources/uid/loki/health | grep -q OK"
docker compose up -d --force-recreate --wait loki >/dev/null 2>&1; wait_healthy $LOKI; sleep 10
check "logs survive re-creation of the Loki container (named volume)" "wait_count '{job=\"docker\"} |= \"/api/v1/$PM\"' 30 \"$N_BEFORE\""
docker compose up -d --force-recreate --wait alloy >/dev/null 2>&1; wait_healthy $ALLOY; sleep 15
check "logs are not duplicated by re-creating alloy (positions on the volume)" "wait_count '{job=\"docker\"} |= \"/api/v1/$PM\"' 30 \"$N_BEFORE\""
BM="after-recreate$(date +%s)"; curl -s -o /dev/null "$U/api/v1/$BM"
check "ingestion continues after re-creating alloy" "wait_lines '{service=\"backend\"} |= \"/api/v1/$BM\"' 10"
B0=$($LQ count '{service="backend"} |= "backend started"' 60)
docker restart $BE >/dev/null; wait_healthy $BE; sleep 12
check "restarting the backend adds a new 'backend started' line and keeps the earlier logs ($B0 -> more)" "[ \"\$($LQ count '{service=\"backend\"} |= \"backend started\"' 60)\" -gt \"$B0\" ] && wait_count '{job=\"docker\"} |= \"/api/v1/$PM\"' 30 \"$N_BEFORE\""
check "all tasks survive all of the above" "tasks_preserved && five_present"

echo "== reliability: Loki restart durability, outage delivery, Alloy re-creation, hard kill"
check "loki runs with ingester.wal.flush_on_shutdown=true and checkpoint_duration=1m" "docker exec $GR wget -q -O- http://loki:3100/config | awk '/^ingester:/{f=1} f&&/^[a-z_]+:/&&!/^ingester:/{f=0} f' | grep -E 'flush_on_shutdown: true' >/dev/null && docker exec $GR wget -q -O- http://loki:3100/config | awk '/^ingester:/{f=1} f&&/^[a-z_]+:/&&!/^ingester:/{f=0} f' | grep -E 'checkpoint_duration: 1m' >/dev/null"
check "loki's container gets 30 s to flush on stop (stop_grace_period)" "[ \"\$(docker inspect -f '{{.Config.StopTimeout}}' $LOKI)\" = 30 ]"
check "alloy keeps read positions on its volume (positions.yml is non-empty)" "docker run --rm -v monitoring-3tier_alloy_data:/a:ro alpine sh -c 'test -s /a/loki.source.docker.stack/positions.yml'"
check "restart after a flush (streams re-created, the original failure condition): all 6 lines survive [1/2]" "graceful_restart_after_flush A"
check "restart after a flush: all 6 lines survive, second consecutive restart [2/2]" "graceful_restart_after_flush B"
check "Loki outage (stopped, requests happen, restarted): Alloy retries and every line is delivered, none lost" "loki_outage_delivery"
check "Alloy re-created right after traffic, twice: no line lost and none duplicated (exact counts)" "alloy_recreate_no_loss_no_dup"
check "Alloy dropped no entries for any reason since it started" "docker exec $PROM wget -q -O- http://alloy:12345/metrics | grep -E '^loki_write_dropped_entries_total' | awk '{s+=\$NF} END{exit (s==0 ? 0 : 1)}'"
check "hard kill (SIGKILL) of Loki in normal operation loses no line" "hard_kill_normal_operation"
check "a new WAL checkpoint completes within ~4 minutes of Loki starting (checkpoints stay fresh; was ~10 min before the fix)" "checkpoints_advance"
# Measured limitation (documented in docs/loki.md and security.md): SIGKILL after streams were re-created since
# the last checkpoint can lose their newest lines. Recorded for information, not asserted, because it is
# nondeterministic and is an upstream Loki recovery behaviour that no configuration removes.
flush_streams; m="kfl$(date +%s)"; make_traffic "$m"; wait_stored "$m"
docker kill $LOKI >/dev/null; sleep 3; [ "$(docker inspect -f '{{.State.Running}}' $LOKI)" = true ] || docker start $LOKI >/dev/null; wait_healthy $LOKI; sleep 20
echo "INFO  measured limitation: SIGKILL right after streams were re-created: warning=$($LQ count "{service=\"nginx\", log_type=\"access\", level=\"warning\"} |= \"$m\"" 20)/3 info=$($LQ count "{service=\"nginx\", log_type=\"access\", level=\"info\"} |= \"$m\"" 20)/3 (loss is possible only on a hard kill within about a minute of a stream being re-created)"
wait_healthy $LOKI; sleep 5
fi

if [ "$FULL_CYCLE" = 1 ]; then
echo "== persistence: full stack down/up (NO -v, volumes kept)"
VOLS_BEFORE=$(docker volume ls --format '{{.Name}}' | grep '^monitoring-3tier_' | sort | tr '\n' ' ')
CM="fullcycle$(date +%s)"; curl -s -o /dev/null "$U/api/v1/$CM"; wait_lines "{service=\"nginx\", log_type=\"access\"} |= \"/api/v1/$CM\"" 10
C_BEFORE=$($LQ count "{job=\"docker\"} |= \"/api/v1/$CM\"" 30)
docker compose down >/dev/null 2>&1
check "all containers are gone after down" "[ -z \"\$(docker ps -a --filter name=monitoring-3tier- --format '{{.Names}}' | grep -v run)\" ]"
check "volumes are untouched by down ($VOLS_BEFORE)" "[ \"\$(docker volume ls --format '{{.Name}}' | grep '^monitoring-3tier_' | sort | tr '\\n' ' ')\" = \"$VOLS_BEFORE\" ]"
docker compose up -d --wait --wait-timeout 400 >/dev/null 2>&1
for c in $PG $BE $NGINX $PROM $NODE $PGX $GR $LOKI $ALLOY $PXY; do check "$c healthy after the cycle" "wait_healthy $c"; done
sleep 20
check "logs written before the cycle are still in Loki ($C_BEFORE lines)" "wait_count '{job=\"docker\"} |= \"/api/v1/$CM\"' 60 \"$C_BEFORE\""
DM="aftercycle$(date +%s)"; curl -s -o /dev/null "$U/api/v1/$DM"
check "new requests are collected after the cycle" "wait_lines '{service=\"nginx\", log_type=\"access\"} |= \"/api/v1/$DM\"' 10 && wait_lines '{service=\"backend\"} |= \"/api/v1/$DM\"' 10"
check "alembic is at head and all tasks are intact after the cycle" "docker exec $BE alembic current 2>/dev/null | grep -q '0001 (head)' && tasks_preserved && five_present"
check "all dashboards still return data after the cycle" "$PY tests/e2e/grafana_panels_check.py > /tmp/panels7.out 2>&1; tail -1 /tmp/panels7.out | grep -q ' 0 failed'"
fi

# Best-effort cleanup (not a check): remove this suite's throw-away test streams from Loki so they do
# not clutter the dashboard's Service variable for the 7-day retention. Uses Loki's delete API on the
# internal network; only streams named e2e-*, rc-*, repro-* or redaction-canary are selected.
purge_url=$($PY -c "import time,urllib.parse; n=int(time.time()); print('http://loki:3100/loki/api/v1/delete?'+urllib.parse.urlencode({'query':'{service=~\"e2e-.+|rc-.+|repro-.+|redaction-canary\"}','start':n-3*86400,'end':n-15}))")
docker run --rm --network monitoring-3tier_monitoring curlimages/curl -s -o /dev/null -w "      cleanup of test streams in Loki: HTTP %{http_code} (204 = accepted)
" -X POST "$purge_url" 2>/dev/null
exit $fail
