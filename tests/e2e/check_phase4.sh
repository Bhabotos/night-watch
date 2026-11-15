#!/bin/sh
# Phase 4 checks: nginx + frontend + network isolation. Needs the stack up and curl on the host.
# Run from the repo root: sh tests/e2e/check_phase4.sh
set -u
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

PORT=$(grep -E '^FRONTEND_HOST_PORT=' .env 2>/dev/null | cut -d= -f2); PORT=${PORT:-8088}
U="http://127.0.0.1:$PORT"
NGINX=monitoring-3tier-nginx-1; BACKEND=monitoring-3tier-backend-1; PG=monitoring-3tier-postgres-1
J='content-type: application/json'
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "== serving and headers ($U)"
check "homepage returns 200 HTML with the app root" "curl -s $U/ | grep -q 'id=\"root\"'"
check "SPA fallback serves index.html for deep links" "[ \"\$(code $U/tasks/42)\" = 200 ] && curl -s $U/tasks/42 | grep -q 'id=\"root\"'"
check "missing file with extension is a real 404" "[ \"\$(code $U/missing.js)\" = 404 ]"
check "dotfiles are not served" "[ \"\$(code $U/.env)\" = 404 ]"
H=$(curl -s -o /dev/null -D - $U/ | tr -d '\r')
for hdr in "X-Content-Type-Options: nosniff" "X-Frame-Options: DENY" "Referrer-Policy: no-referrer" "Content-Security-Policy: default-src 'self'" "Cross-Origin-Opener-Policy: same-origin"; do
  check "header present: ${hdr%%:*}" "echo \"\$H\" | grep -qF \"$hdr\""
done
check "nginx version is not disclosed" "echo \"\$H\" | grep -qi '^Server: nginx\$'"
check "built page has no inline script (CSP-safe)" "! curl -s $U/ | grep -E '<script[^>]*>[^<]+</script>' | grep -q ."

echo "== API reverse proxy"
check "POST /api/v1/tasks -> 201" "[ \"\$(code -X POST $U/api/v1/tasks -H '$J' -d '{\"title\":\"e2e phase4\"}')\" = 201 ]"
ID=$(curl -s "$U/api/v1/tasks?limit=1" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
check "GET list works" "curl -s '$U/api/v1/tasks?limit=1' | grep -q 'e2e phase4'"
check "PATCH -> 200 and status changed" "curl -s -X PATCH $U/api/v1/tasks/$ID -H '$J' -d '{\"status\":\"done\"}' | grep -q '\"status\":\"done\"'"
check "DELETE -> 204" "[ \"\$(code -X DELETE $U/api/v1/tasks/$ID)\" = 204 ]"
check "deleted task -> 404 JSON error" "curl -s $U/api/v1/tasks/$ID | grep -q task_not_found"
check "invalid body -> 422 passed through" "[ \"\$(code -X POST $U/api/v1/tasks -H '$J' -d '{\"title\":\"\"}')\" = 422 ]"
check "oversized body -> 413" "head -c 100000 /dev/zero | tr '\\0' a | { printf '{\"title\":\"x\",\"description\":\"'; cat; printf '\"}'; } | [ \"\$(curl -s -o /dev/null -w '%{http_code}' -X POST $U/api/v1/tasks -H '$J' --data-binary @-)\" = 413 ]"
check "OPTIONS and TRACE are refused" "[ \"\$(code -X OPTIONS $U/api/v1/tasks)\" = 403 ] && [ \"\$(code -X TRACE $U/api/v1/tasks)\" = 405 ]"
check "backend /metrics is not reachable through nginx" "! curl -s $U/metrics | grep -q http_requests_total"
check "backend /health body is not exposed (SPA html only)" "! curl -s $U/health | grep -q '\"status\"'"
check "unknown /api path -> JSON 404 from nginx" "[ \"\$(code $U/api/health)\" = 404 ] && [ \"\$(code $U/api/docs)\" = 404 ]"
check "API responses are not cacheable" "curl -s -o /dev/null -D - '$U/api/v1/tasks?limit=1' | grep -qi '^cache-control: no-store'"

echo "== logging"
curl -s -o /dev/null "$U/api/v1/tasks?limit=1&token=QUERY-SECRET-CHECK"
sleep 1
check "query strings are not in nginx logs" "[ \"\$(docker logs $NGINX 2>&1 | grep -c QUERY-SECRET-CHECK)\" = 0 ]"
check "query strings are not in backend logs" "[ \"\$(docker logs $BACKEND 2>&1 | grep -c QUERY-SECRET-CHECK)\" = 0 ]"
check "nginx access log is JSON with request_id" "docker logs $NGINX 2>&1 | grep '\"path\":\"/api/v1/tasks\"' | tail -1 | grep -q '\"request_id\":\"[a-f0-9]\\{32\\}\"'"

echo "== network isolation"
check "nginx is on exactly edge + proxy" "[ \"\$(docker inspect -f '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' $NGINX | tr ' ' '\\n' | sort | tr -d '\\n')\" = 'monitoring-3tier_edgemonitoring-3tier_proxy' ]"
check "backend is still on exactly application + metrics + proxy" "[ \"\$(docker inspect -f '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' $BACKEND | tr ' ' '\\n' | sort | tr -d '\\n')\" = 'monitoring-3tier_applicationmonitoring-3tier_metricsmonitoring-3tier_proxy' ]"
check "only nginx publishes a host port (127.0.0.1)" "[ \"\$(docker compose ps --format '{{.Name}}={{.Ports}}' | grep -c '0.0.0.0\\|\\[::\\]')\" = 0 ] && docker port $NGINX | grep -q '^8080/tcp -> 127.0.0.1:'"
check "backend publishes no host port" "[ -z \"\$(docker port $BACKEND)\" ]"
check "postgres publishes no host port" "[ -z \"\$(docker port $PG)\" ]"
check "nginx cannot resolve or reach postgres" "! docker exec $NGINX sh -c 'getent hosts postgres' >/dev/null 2>&1 && ! docker exec $NGINX sh -c 'wget -T2 -q -O /dev/null http://postgres:5432' >/dev/null 2>&1"
PGIP=$(docker inspect -f '{{(index .NetworkSettings.Networks "monitoring-3tier_application").IPAddress}}' $PG)
check "tool available in nginx for the TCP test (nc)" "docker exec $NGINX which nc >/dev/null"
check "nginx cannot open a TCP connection to postgres:5432 by IP" "! docker exec $NGINX nc -z -w2 $PGIP 5432"
check "control: backend can open a TCP connection to postgres:5432" "docker exec $BACKEND python -c \"import socket; socket.create_connection(('postgres',5432),timeout=3).close()\""
check "backend can still reach postgres (tasks list hits the DB)" "[ \"\$(code '$U/api/v1/tasks?limit=1')\" = 200 ]"
check "backend /ready is ok (DB reachable)" "docker exec $BACKEND python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/ready',timeout=3).status==200 else 1)\""

echo "== container hardening"
check "nginx runs as non-root" "[ \"\$(docker exec $NGINX id -u)\" != 0 ]"
check "nginx rootfs is read-only, caps dropped, no-new-privileges" "[ \"\$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' $NGINX)\" = 'true [ALL] [no-new-privileges:true]' ]"
check "nginx stop signal is SIGQUIT (graceful)" "[ \"\$(docker inspect -f '{{.Config.StopSignal}}' $NGINX)\" = SIGQUIT ]"
check "nginx container is healthy" "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $NGINX)\" = healthy ]"
exit $fail
