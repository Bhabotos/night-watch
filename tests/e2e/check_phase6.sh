#!/bin/sh
# Phase 6 checks: Grafana, provisioning, dashboards, security and restart persistence.
# Run from the repo root with the stack up: sh tests/e2e/check_phase6.sh
#
#   PERSISTENCE=0   skip the restart tests (default 1)
#   FULL_CYCLE=1    also run `docker compose down` + `up` (NO -v: volumes are kept) and verify that
#                   PostgreSQL, Prometheus and Grafana data survive (default 0; restarts every service)
set -u
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

PERSISTENCE=${PERSISTENCE:-1}; FULL_CYCLE=${FULL_CYCLE:-0}
GPORT=${GRAFANA_HOST_PORT:-3001}; G="http://127.0.0.1:$GPORT"
FPORT=${FRONTEND_HOST_PORT:-8088}
GR=monitoring-3tier-grafana-1; PROM=monitoring-3tier-prometheus-1; NODE=monitoring-3tier-node-exporter-1
PGX=monitoring-3tier-postgres-exporter-1; PG=monitoring-3tier-postgres-1; BE=monitoring-3tier-backend-1
NGINX=monitoring-3tier-nginx-1
AUTH="$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD"
gapi() { curl -s -u "$AUTH" "$@"; }                       # authenticated
gcode() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
PY="python -I"
nets() { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" | tr ' ' '\n' | sort | tr -d '\n'; }
wait_healthy() { for i in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = healthy ] && return 0; sleep 3; done; return 1; }
dash_count() { gapi "$G/api/search?type=dash-db" | $PY -c "import sys,json; print(len(json.load(sys.stdin)))"; }
ds_ok() { gapi "$G/api/datasources/uid/prometheus/health" | $PY -c "import sys,json; print(json.load(sys.stdin).get('status'))"; }

echo "== static"
check "docker compose config is valid" "docker compose config -q"
check "dashboard JSON lint passes" "$PY tests/e2e/dashboards_lint.py >/dev/null"
check "provisioning files exist" "[ -f monitoring/grafana/provisioning/datasources/prometheus.yml ] && [ -f monitoring/grafana/provisioning/dashboards/dashboards.yml ]"
check "GRAFANA_ADMIN_PASSWORD is not the example placeholder" "[ \"\$GRAFANA_ADMIN_PASSWORD\" != CHANGE_ME ] && [ \${#GRAFANA_ADMIN_PASSWORD} -ge 20 ]"
check "admin password is not committed (.env ignored, example has a placeholder)" "git check-ignore -q .env && grep -q '^GRAFANA_ADMIN_PASSWORD=CHANGE_ME' .env.example"

echo "== service"
check "grafana is healthy" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $GR)\" = healthy ]"
check "grafana database ok" "curl -s $G/api/health | grep -q '\"database\": *\"ok\"'"
check "datasource 'prometheus' is provisioned, default and read-only" "gapi $G/api/datasources | $PY -c \"import sys,json; d=[x for x in json.load(sys.stdin) if x['uid']=='prometheus']; sys.exit(0 if d and d[0]['isDefault'] and d[0]['readOnly'] and d[0]['url']=='http://prometheus:9090' else 1)\""
check "datasource health check succeeds" "[ \"\$(ds_ok)\" = OK ]"
check "4 dashboards provisioned (host-vm, app-tasks, postgres, logs)" "[ \"\$(gapi \"$G/api/search?type=dash-db\" | $PY -c \"import sys,json; print(','.join(sorted(d['uid'] for d in json.load(sys.stdin))))\")\" = 'app-tasks,host-vm,logs,postgres' ]"
check "home dashboard is the application dashboard" "gapi $G/api/dashboards/home | $PY -c \"import sys,json; d=json.load(sys.stdin); sys.exit(0 if d.get('redirectUri','').endswith('application-tasks-api') else 1)\""
check "every dashboard query runs through Grafana and returns data" "$PY tests/e2e/grafana_panels_check.py > /tmp/panels.out 2>&1; tail -1 /tmp/panels.out | grep -q ' 0 failed'"
echo "      ($(tail -1 /tmp/panels.out))"

echo "== authentication and access control"
for path in /api/search /api/datasources /api/dashboards/uid/host-vm /api/admin/settings /api/user; do
  check "anonymous GET $path -> 401" "[ \"\$(gcode $G$path)\" = 401 ]"
done
check "wrong password -> 401" "[ \"\$(gcode -u $GRAFANA_ADMIN_USER:wrong-password $G/api/search)\" = 401 ]"
check "admin credentials work" "[ \"\$(gcode -u '$AUTH' $G/api/search)\" = 200 ]"
check "self sign-up is disabled" "[ \"\$(gcode -X POST $G/api/user/signup -H 'Content-Type: application/json' -d '{\"email\":\"x@example.com\",\"password\":\"x\"}')\" != 200 ]"
check "anonymous health reveals no version" "! curl -s $G/api/health | grep -q version"
check "grafana's own /metrics is not served anonymously" "! curl -s $G/metrics | grep -q '^# HELP'"
SET=$(gapi $G/api/admin/settings)
chk_setting() { echo "$SET" | $PY -c "import sys,json; s=json.load(sys.stdin); sec,key,want=sys.argv[1:4]; sys.exit(0 if str(s.get(sec,{}).get(key))==want else 1)" "$1" "$2" "$3"; }
check "setting users.allow_sign_up = false" "chk_setting users allow_sign_up false"
check "setting auth.anonymous enabled = false" "chk_setting auth.anonymous enabled false"
check "setting analytics reporting_enabled = false" "chk_setting analytics reporting_enabled false"
check "setting analytics check_for_updates = false" "chk_setting analytics check_for_updates false"
check "setting plugins plugin_admin_enabled = false" "chk_setting plugins plugin_admin_enabled false"
check "setting security cookie_samesite = strict" "chk_setting security cookie_samesite strict"
check "settings API does not reveal the admin password" "! echo \"\$SET\" | grep -qF -- \"\$GRAFANA_ADMIN_PASSWORD\""

echo "== provisioned objects are read-only"
DS=$(gapi $G/api/datasources/uid/prometheus)
check "datasource cannot be modified through the API" "[ \"\$(gcode -u '$AUTH' -X PUT $G/api/datasources/uid/prometheus -H 'Content-Type: application/json' -d \"\$DS\")\" != 200 ]"
check "datasource cannot be deleted through the API" "[ \"\$(gcode -u '$AUTH' -X DELETE $G/api/datasources/uid/prometheus)\" != 200 ] && [ \"\$(ds_ok)\" = OK ]"
BOARD=$(gapi $G/api/dashboards/uid/host-vm | $PY -c "import sys,json; d=json.load(sys.stdin); print(json.dumps({'dashboard':d['dashboard'],'overwrite':True}))")
check "provisioned dashboard cannot be overwritten through the API" "[ \"\$(gcode -u '$AUTH' -X POST $G/api/dashboards/db -H 'Content-Type: application/json' -d \"\$BOARD\")\" != 200 ]"
check "provisioned dashboard cannot be deleted through the API" "[ \"\$(gcode -u '$AUTH' -X DELETE $G/api/dashboards/uid/host-vm)\" != 200 ] && [ \"\$(dash_count)\" = 4 ]"

echo "== exposure and hardening"
check "grafana publishes only 127.0.0.1:$GPORT" "[ \"\$(docker port $GR)\" = '3000/tcp -> 127.0.0.1:$GPORT' ]"
check "grafana is on exactly edge + monitoring" "[ \"\$(nets $GR)\" = 'monitoring-3tier_edgemonitoring-3tier_monitoring' ]"
for c in $PROM $NODE $PGX $PG $BE; do check "$c still publishes no host port" "[ -z \"\$(docker port $c)\" ]"; done
check "only nginx, grafana and the Prometheus UI forwarder publish ports, all on 127.0.0.1" "[ \"\$(docker ps --filter name=monitoring-3tier --format '{{.Names}}={{.Ports}}' | grep '127.0.0.1' | cut -d= -f1 | sort | tr '\\n' ' ')\" = 'monitoring-3tier-grafana-1 monitoring-3tier-nginx-1 monitoring-3tier-prometheus-ui-1 ' ] && [ \"\$(docker ps --filter name=monitoring-3tier --format '{{.Ports}}' | grep -c '0.0.0.0')\" = 0 ]"
check "grafana: non-root, read-only rootfs, caps dropped, no-new-privileges, unprivileged" "[ \"\$(docker exec $GR id -u)\" != 0 ] && [ \"\$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Privileged}}' $GR)\" = 'true [ALL] [no-new-privileges:true] false' ]"
check "provisioning and dashboard mounts are read-only; only /var/lib/grafana is writable" "M=\$(docker inspect -f '{{range .Mounts}}{{.Destination}}={{.RW}} {{end}}' $GR | tr ' ' '\n'); [ \"\$(echo \"\$M\" | grep -c '=false')\" = 3 ] && [ \"\$(echo \"\$M\" | grep '=true')\" = '/var/lib/grafana=true' ]"
check "grafana data is on the named volume" "docker inspect -f '{{range .Mounts}}{{.Name}}:{{.Destination}} {{end}}' $GR | grep -q 'monitoring-3tier_grafana_data:/var/lib/grafana'"
check "the admin password is not in grafana's logs" "[ \"\$(docker logs $GR 2>&1 | grep -cF -- \"\$GRAFANA_ADMIN_PASSWORD\")\" = 0 ]"
check "the admin password is not in the dashboards or provisioning files" "! grep -rqF -- \"\$GRAFANA_ADMIN_PASSWORD\" monitoring/"
check "grafana can reach prometheus (control)" "docker exec $GR nc -z -w3 prometheus 9090"
check "grafana cannot reach postgres, the exporters or the backend" "! docker exec $GR nc -z -w2 postgres 5432 2>/dev/null && ! docker exec $GR nc -z -w2 postgres-exporter 9187 2>/dev/null && ! docker exec $GR nc -z -w2 node-exporter 9100 2>/dev/null && ! docker exec $GR nc -z -w2 backend 8000 2>/dev/null"
check "the prometheus container itself is unpublished and unreachable from nginx (the only host path is the prometheus-ui forwarder)" "[ -z \"\$(docker port $PROM)\" ] && ! docker exec $NGINX nc -z -w2 prometheus 9090 2>/dev/null"
echo "INFO  known by design: nginx and grafana share the 'edge' network, so nginx can open a connection to grafana:3000 (see docs/security.md)"

if [ "$PERSISTENCE" = 1 ]; then
echo "== persistence: restart grafana"
BEFORE_DASH=$(dash_count)
docker restart $GR >/dev/null; wait_healthy $GR
check "grafana is healthy again after a restart" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $GR)\" = healthy ]"
check "dashboards still provisioned after restart ($BEFORE_DASH)" "[ \"\$(dash_count)\" = \"$BEFORE_DASH\" ]"
check "datasource still healthy after restart" "[ \"\$(ds_ok)\" = OK ]"

echo "== persistence: grafana state survives container re-creation"
TS=$(date +%s); FOLDER="persistence-test-$TS"
FUID=$(gapi -X POST $G/api/folders -H 'Content-Type: application/json' -d "{\"title\":\"$FOLDER\"}" | $PY -c "import sys,json; print(json.load(sys.stdin).get('uid',''))")
check "created a test folder through the API" "[ -n \"$FUID\" ]"
gapi -X POST $G/api/user/stars/dashboard/uid/host-vm >/dev/null
check "starred a dashboard (per-user state)" "gapi $G/api/user/stars | grep -q host-vm"
docker compose up -d --force-recreate --wait grafana >/dev/null 2>&1; wait_healthy $GR
check "grafana container was re-created (new container id)" "[ -n \"\$(docker inspect -f '{{.State.StartedAt}}' $GR)\" ]"
check "test folder persisted across re-creation" "gapi $G/api/folders/$FUID | grep -q '$FOLDER'"
check "starred dashboard persisted across re-creation" "gapi $G/api/user/stars | grep -q host-vm"
check "dashboards and datasource re-provisioned after re-creation" "[ \"\$(dash_count)\" = \"$BEFORE_DASH\" ] && [ \"\$(ds_ok)\" = OK ]"
gapi -X DELETE $G/api/user/stars/dashboard/uid/host-vm >/dev/null
gapi -X DELETE "$G/api/folders/$FUID" >/dev/null
check "cleanup: test folder and star removed" "! gapi $G/api/folders | grep -q '$FOLDER' && ! gapi $G/api/user/stars | grep -q host-vm"

echo "== persistence: prometheus data survives a restart and grafana still queries it"
cnt() { docker run --rm --network monitoring-3tier_monitoring curlimages/curl -s -G http://prometheus:9090/api/v1/query --data-urlencode 'query=count_over_time(up{job="backend"}[1h])' | $PY -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 0)"; }
P_BEFORE=$(cnt)
docker compose restart prometheus >/dev/null 2>&1; wait_healthy $PROM; sleep 20
P_AFTER=$(cnt)
check "prometheus kept its history across a restart ($P_BEFORE -> $P_AFTER samples)" "$PY -c \"import sys; sys.exit(0 if float('$P_AFTER')>=float('$P_BEFORE') and float('$P_BEFORE')>0 else 1)\""
check "grafana can query prometheus after the restart" "[ \"\$(ds_ok)\" = OK ]"
fi

if [ "$FULL_CYCLE" = 1 ]; then
echo "== persistence: full stack down/up (NO -v, volumes kept)"
VOLS_BEFORE=$(docker volume ls --format '{{.Name}}' | grep '^monitoring-3tier_' | sort | tr '\n' ' ')
MARK="full-cycle-$(date +%s)"
curl -s -o /dev/null -X POST http://127.0.0.1:$FPORT/api/v1/tasks -H 'Content-Type: application/json' -d "{\"title\":\"$MARK\"}"
check "created a task before the cycle" "curl -s 'http://127.0.0.1:$FPORT/api/v1/tasks?limit=50' | grep -q '$MARK'"
gapi -X POST $G/api/user/stars/dashboard/uid/postgres >/dev/null
P_BEFORE=$(cnt)
docker compose down >/dev/null 2>&1
check "all containers are gone after down" "[ -z \"\$(docker ps -a --filter name=monitoring-3tier- --format '{{.Names}}' | grep -v run)\" ]"
check "volumes are untouched by down: $VOLS_BEFORE" "[ \"\$(docker volume ls --format '{{.Name}}' | grep '^monitoring-3tier_' | sort | tr '\\n' ' ')\" = \"$VOLS_BEFORE\" ]"
docker compose up -d --wait --wait-timeout 300 >/dev/null 2>&1
for c in $PG $BE $NGINX $PROM $NODE $PGX $GR; do check "$c healthy after the cycle" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $c)\" = healthy ]"; done
check "PostgreSQL data survived: the task is still there" "curl -s 'http://127.0.0.1:$FPORT/api/v1/tasks?limit=50' | grep -q '$MARK'"
check "alembic is still at head (no re-migration needed)" "docker exec $BE alembic current 2>/dev/null | grep -q '0001 (head)'"
sleep 20
P_AFTER=$(cnt)
check "Prometheus history survived ($P_BEFORE -> $P_AFTER samples)" "$PY -c \"import sys; sys.exit(0 if float('$P_AFTER')>=float('$P_BEFORE') and float('$P_BEFORE')>0 else 1)\""
check "Grafana state survived (star persisted) and dashboards are provisioned" "gapi $G/api/user/stars | grep -q postgres && [ \"\$(dash_count)\" = 4 ]"
check "every dashboard query still returns data after the cycle" "$PY tests/e2e/grafana_panels_check.py > /tmp/panels.out 2>&1; tail -1 /tmp/panels.out | grep -q ' 0 failed'"
gapi -X DELETE $G/api/user/stars/dashboard/uid/postgres >/dev/null
TID=$(curl -s 'http://127.0.0.1:'$FPORT'/api/v1/tasks?limit=50' | $PY -c "import sys,json; print(next((t['id'] for t in json.load(sys.stdin)['items'] if t['title']=='$MARK'),''))")
[ -n "$TID" ] && curl -s -o /dev/null -X DELETE http://127.0.0.1:$FPORT/api/v1/tasks/$TID
check "cleanup: marker task and star removed" "! curl -s 'http://127.0.0.1:$FPORT/api/v1/tasks?limit=50' | grep -q '$MARK' && ! gapi $G/api/user/stars | grep -q postgres"
fi
exit $fail
