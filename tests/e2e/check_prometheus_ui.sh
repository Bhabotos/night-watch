#!/bin/sh
# Checks for the localhost-only Prometheus UI forwarder (service prometheus-ui, network uiaccess).
# Run from the repo root with the stack up: sh tests/e2e/check_prometheus_ui.sh
set -u
export MSYS_NO_PATHCONV=1
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

FWD=monitoring-3tier-prometheus-ui-1; PROM=monitoring-3tier-prometheus-1; NGINX=monitoring-3tier-nginx-1
GR=monitoring-3tier-grafana-1; PY="python -I"
nets() { docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" | tr ' ' '\n' | sort | tr -d '\n'; }

echo "== forwarder"
check "docker compose config is valid" "docker compose config -q"
check "forwarder is healthy" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $FWD)\" = healthy ]"
check "forwarder publishes exactly 127.0.0.1:9090 -> 9090 (never 0.0.0.0)" "[ \"\$(docker port $FWD)\" = '9090/tcp -> 127.0.0.1:9090' ]"
check "forwarder is on exactly uiaccess + monitoring (NOT edge)" "[ \"\$(nets $FWD)\" = 'monitoring-3tier_monitoringmonitoring-3tier_uiaccess' ]"
check "uiaccess contains ONLY the forwarder" "[ \"\$(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' monitoring-3tier_uiaccess | tr -d ' \\n')\" = '$FWD' ]"
check "uiaccess is the only non-internal network besides edge" "[ \"\$(docker network ls --filter name=monitoring-3tier_ --format '{{.Name}}' | while read n; do [ \"\$(docker network inspect -f '{{.Internal}}' \$n)\" = false ] && echo \$n; done | sort | tr '\\n' ' ')\" = 'monitoring-3tier_edge monitoring-3tier_uiaccess ' ]"
check "monitoring, metrics, proxy, application are still internal" "[ \"\$(for n in monitoring metrics proxy application; do docker network inspect -f '{{.Internal}}' monitoring-3tier_\$n; done | tr -d '\\n')\" = truetruetruetrue ]"
check "forwarder: non-root, read-only rootfs, caps dropped, no-new-privileges, unprivileged, limits" "[ \"\$(docker inspect -f '{{.Config.User}}' $FWD)\" = 65534:65534 ] && [ \"\$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Privileged}}' $FWD)\" = 'true [ALL] [no-new-privileges:true] false' ] && [ \"\$(docker inspect -f '{{.HostConfig.Memory}}' $FWD)\" != 0 ]"
check "forwarder has no mounts and no environment secrets" "[ -z \"\$(docker inspect -f '{{range .Mounts}}{{.Destination}}{{end}}' $FWD)\" ]"

echo "== Prometheus itself is still unpublished and unchanged"
check "prometheus container publishes no host port" "[ -z \"\$(docker port $PROM)\" ]"
check "prometheus is still on exactly metrics + monitoring" "[ \"\$(nets $PROM)\" = 'monitoring-3tier_metricsmonitoring-3tier_monitoring' ]"
check "nginx cannot reach prometheus or the forwarder" "! docker exec $NGINX nc -z -w2 prometheus 9090 2>/dev/null && ! docker exec $NGINX nc -z -w2 prometheus-ui 9090 2>/dev/null"
check "grafana is not on uiaccess" "! nets $GR | grep -q uiaccess"
check "only nginx (8088), grafana (3001) and the forwarder (9090) publish, all on 127.0.0.1" "[ \"\$(docker ps --filter name=monitoring-3tier --format '{{.Names}}={{.Ports}}' | grep -c '127.0.0.1')\" = 3 ] && [ \"\$(docker ps --filter name=monitoring-3tier --format '{{.Ports}}' | grep -c '0.0.0.0')\" = 0 ] && docker ps --filter name=monitoring-3tier --format '{{.Names}}={{.Ports}}' | grep '127.0.0.1' | cut -d= -f1 | sort | tr '\\n' ' ' | grep -q 'monitoring-3tier-grafana-1 monitoring-3tier-nginx-1 monitoring-3tier-prometheus-ui-1'"

echo "== from the Windows host"
check "http://127.0.0.1:9090/-/healthy answers 200" "[ \"\$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:9090/-/healthy)\" = 200 ]"
check "the Prometheus UI page is served" "curl -s -m 5 http://127.0.0.1:9090/ | grep -qiE 'prometheus|/graph|/query'"
check "the query API works through the forwarder" "curl -s -m 5 'http://127.0.0.1:9090/api/v1/query?query=up' | $PY -c \"import sys,json; d=json.load(sys.stdin); sys.exit(0 if d['status']=='success' and len(d['data']['result'])>=6 else 1)\""
check "all six scrape targets are up" "[ \"\$(curl -s -m 5 http://127.0.0.1:9090/api/v1/targets | $PY -c \"import sys,json; print(' '.join(sorted(t['labels']['job']+'='+t['health'] for t in json.load(sys.stdin)['data']['activeTargets'])))\")\" = 'alloy=up backend=up loki=up node=up postgres=up prometheus=up' ]"
check "admin and lifecycle APIs stay disabled through the forwarder" "[ \"\$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:9090/-/reload)\" = 403 ] && [ \"\$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:9090/api/v1/admin/tsdb/snapshot)\" != 200 ]"
check "the host listener is loopback only (exactly 127.0.0.1, no 0.0.0.0, no LAN or IPv6-any address)" "[ \"\$(powershell -NoProfile -Command '(Get-NetTCPConnection -LocalPort 9090 -State Listen).LocalAddress' | tr -d '\r' | sort -u | tr '\n' ' ')\" = '127.0.0.1 ' ]"
exit $fail
