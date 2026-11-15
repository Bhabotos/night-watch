#!/bin/sh
# Phase 5 checks: Prometheus, node-exporter, postgres-exporter.
# Needs the stack up. Prometheus is not published, so queries run from a throw-away curl
# container on the internal `monitoring` network.
# Run from the repo root: sh tests/e2e/check_phase5.sh
set -u
export MSYS_NO_PATHCONV=1
set -a; . ./.env; set +a
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

PROM=monitoring-3tier-prometheus-1; NODE=monitoring-3tier-node-exporter-1; PGX=monitoring-3tier-postgres-exporter-1
NGINX=monitoring-3tier-nginx-1; BACKEND=monitoring-3tier-backend-1; PG=monitoring-3tier-postgres-1
PROM_IMAGE=$(sed -n 's#^    image: \(prom/prometheus:.*\)#\1#p' docker-compose.yml)
curlm() { docker run --rm --network monitoring-3tier_monitoring curlimages/curl -s "$@"; }
# value of an instant query (first series) or "none"
qval() { curlm -G http://prometheus:9090/api/v1/query --data-urlencode "query=$1" | python -I -c "
import sys,json
r=json.load(sys.stdin)['data']['result']
print(r[0]['value'][1] if r else 'none')"; }
nets() { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" | tr ' ' '\n' | sort | tr -d '\n'; }

echo "== configuration (promtool, $PROM_IMAGE)"
W=$(pwd -W 2>/dev/null || pwd)
check "prometheus.yml is valid" "docker run --rm -v $W:/work -w /work --entrypoint promtool $PROM_IMAGE check config monitoring/prometheus/prometheus.yml >/dev/null"
check "recording rules are valid" "docker run --rm -v $W:/work -w /work --entrypoint promtool $PROM_IMAGE check rules monitoring/prometheus/rules/recording.yml >/dev/null"
check "recording rule unit tests pass" "docker run --rm -v $W:/work -w /work/tests/prometheus --entrypoint promtool $PROM_IMAGE test rules recording_rules_test.yml >/dev/null"

echo "== containers"
for c in $PROM $NODE $PGX; do check "$c is healthy" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $c)\" = healthy ]"; done
check "prometheus on metrics + monitoring only" "[ \"\$(nets $PROM)\" = 'monitoring-3tier_metricsmonitoring-3tier_monitoring' ]"
check "node-exporter on metrics only" "[ \"\$(nets $NODE)\" = 'monitoring-3tier_metrics' ]"
check "postgres-exporter on application + metrics only" "[ \"\$(nets $PGX)\" = 'monitoring-3tier_applicationmonitoring-3tier_metrics' ]"
check "monitoring and metrics networks are internal" "[ \"\$(docker network inspect -f '{{.Internal}}' monitoring-3tier_monitoring monitoring-3tier_metrics | tr -d '\\n')\" = 'truetrue' ]"
for c in $PROM $NODE $PGX; do check "$c publishes no host port" "[ -z \"\$(docker port $c)\" ]"; done

echo "== scraping"
TARGETS=$(curlm http://prometheus:9090/api/v1/targets | python -I -c "
import sys,json
print(' '.join(sorted(t['labels']['job']+'='+t['health'] for t in json.load(sys.stdin)['data']['activeTargets'])))")
check "all 6 targets are up ($TARGETS)" "[ \"\$TARGETS\" = 'alloy=up backend=up loki=up node=up postgres=up prometheus=up' ]"
check "pg_up == 1 (exporter reaches PostgreSQL)" "[ \"\$(qval 'pg_up')\" = 1 ]"
check "backend custom metrics are scraped (tasks_count)" "[ \"\$(qval 'count(tasks_count)')\" = 3 ]"
check "backend HTTP metrics are scraped" "[ \"\$(qval 'count(http_requests_total)')\" != none ]"
check "node metrics are scraped" "[ \"\$(qval 'count(node_cpu_seconds_total)')\" != none ]"
check "postgres metrics are scraped" "[ \"\$(qval 'count(pg_stat_database_xact_commit)')\" != none ]"
check "exporter role is not a superuser and is a member of pg_monitor" "[ \"\$(docker exec -e PGPASSWORD=\"\$POSTGRES_ADMIN_PASSWORD\" $PG psql -h 127.0.0.1 -U \"\$POSTGRES_ADMIN_USER\" -d postgres -Atc \"select rolsuper, pg_has_role(rolname,'pg_monitor','member') from pg_roles where rolname='\$EXPORTER_DB_USER'\")\" = 'f|t' ]"
check "exporter session is connected as that role" "[ \"\$(docker exec -e PGPASSWORD=\"\$POSTGRES_ADMIN_PASSWORD\" $PG psql -h 127.0.0.1 -U \"\$POSTGRES_ADMIN_USER\" -d postgres -Atc \"select count(*)>0 from pg_stat_activity where usename='\$EXPORTER_DB_USER'\")\" = t ]"

echo "== rules"
RULES=$(curlm http://prometheus:9090/api/v1/rules | python -I -c "
import sys,json
g=json.load(sys.stdin)['data']['groups']
rules=[r for x in g for r in x['rules']]
print(len(rules), sum(r['health']=='ok' for r in rules))")
check "all recording rules load and evaluate ($RULES = total ok)" "[ \"\$RULES\" = '11 11' ]"
for r in app:http_requests:rate5m app:http_errors:ratio_rate5m instance:node_cpu_utilisation:ratio instance:node_memory_utilisation:ratio postgres:connections:ratio; do
  check "recorded series exists: $r" "[ \"\$(qval '$r')\" != none ]"
done
check "error ratio is a number between 0 and 1" "python -I -c \"import sys; v=float('\$(qval app:http_errors:ratio_rate5m)'); sys.exit(0 if 0<=v<=1 else 1)\""
check "CPU utilisation is plausible (not the WSL2 idle-counter artefact)" "python -I -c \"import sys; v=float('\$(qval instance:node_cpu_utilisation:ratio)'); sys.exit(0 if 0<=v<=0.6 else 1)\""

echo "== hardening"
FLAGS=$(curlm http://prometheus:9090/api/v1/status/flags | python -I -c "
import sys,json
f=json.load(sys.stdin)['data']
print(f['storage.tsdb.retention.time'], f['storage.tsdb.retention.size'], f['web.enable-lifecycle'], f['web.enable-admin-api'])")
check "retention 15d / 2GiB, lifecycle and admin APIs disabled ($FLAGS)" "[ \"\$FLAGS\" = '15d 2GiB false false' ]"
check "lifecycle endpoint is refused" "[ \"\$(curlm -o /dev/null -w '%{http_code}' -X POST http://prometheus:9090/-/reload)\" = 403 ]"
check "admin API is refused" "[ \"\$(curlm -o /dev/null -w '%{http_code}' -X POST http://prometheus:9090/api/v1/admin/tsdb/snapshot)\" != 200 ]"
for c in $PROM $NODE $PGX; do
  check "$c: non-root, read-only rootfs, caps dropped, no-new-privileges, unprivileged" "[ \"\$(docker exec $c id -u)\" != 0 ] && [ \"\$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Privileged}}' $c)\" = 'true [ALL] [no-new-privileges:true] false' ]"
done
check "node-exporter does not use host network or host pid" "[ \"\$(docker inspect -f '{{.HostConfig.NetworkMode}} [{{.HostConfig.PidMode}}]' $NODE)\" != 'host []' ] && [ \"\$(docker inspect -f '{{.HostConfig.PidMode}}' $NODE)\" != host ]"
check "node-exporter has NO host bind mounts (Windows drives are not exposed)" "[ -z \"\$(docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' $NODE)\" ]"
check "node-exporter cannot read host or Windows files" "! docker exec $NODE timeout 8 ls /host >/dev/null 2>&1 && ! docker exec $NODE timeout 8 ls /mnt/host >/dev/null 2>&1"
check "prometheus volume is a named volume" "docker volume inspect monitoring-3tier_prometheus_data >/dev/null"

echo "== secrets"
for name in EXPORTER_DB_PASSWORD APP_DB_PASSWORD POSTGRES_ADMIN_PASSWORD; do
  eval v=\$$name
  check "$name not in prometheus/exporter logs" "[ \"\$( (docker logs $PROM; docker logs $NODE; docker logs $PGX) 2>&1 | grep -cF -- \"$v\")\" = 0 ]"
  check "$name not in scraped exporter metrics or targets" "[ \"\$( (curlm http://postgres-exporter:9187/metrics; curlm http://node-exporter:9100/metrics 2>/dev/null; curlm http://prometheus:9090/api/v1/targets) | grep -cF -- \"$v\")\" = 0 ]"
done

echo "== isolation"
check "nginx cannot reach prometheus, node-exporter or postgres-exporter" "! docker exec $NGINX nc -z -w2 prometheus 9090 2>/dev/null && ! docker exec $NGINX nc -z -w2 node-exporter 9100 2>/dev/null && ! docker exec $NGINX nc -z -w2 postgres-exporter 9187 2>/dev/null"
check "prometheus cannot reach postgres" "! docker exec $PROM nc -z -w2 postgres 5432 2>/dev/null"
check "control: prometheus can reach backend:8000 and node-exporter:9100" "docker exec $PROM nc -z -w2 backend 8000 && docker exec $PROM nc -z -w2 node-exporter 9100"
check "no internet egress from prometheus, node-exporter, postgres-exporter" "! docker exec $PROM wget -q -T3 -O /dev/null http://1.1.1.1 2>/dev/null && ! docker exec $NODE wget -q -T3 -O /dev/null http://1.1.1.1 2>/dev/null && ! docker exec $PGX wget -q -T3 -O /dev/null http://1.1.1.1 2>/dev/null"
check "control: nginx (edge) does have egress" "docker exec $NGINX wget -q -T5 -O /dev/null http://1.1.1.1 2>/dev/null || docker exec $NGINX nc -z -w3 1.1.1.1 80 2>/dev/null"
exit $fail
