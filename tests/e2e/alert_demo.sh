#!/bin/sh
# Night Watch controlled alert demonstration: frontend DOWN -> FrontendDown fires -> Telegram -> recovery -> resolved.
# Run from the repo root with the stack up: sh tests/e2e/alert_demo.sh
#   CHANNEL=webhook (default)  delivery to the local alert-sink receiver (no credentials; see `docker logs`)
#   CHANNEL=telegram           delivery to Telegram (needs TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID in .env)
#
# ONLY the nginx container is stopped (about 3 minutes), then started again - also on Ctrl-C or error (trap).
# Backend, PostgreSQL, Prometheus, Grafana, Loki, Alloy, Alertmanager and Blackbox are never touched.
# It prints no credentials. Delivery is evidenced by Alertmanager's own notification counters and, for the
# webhook channel, by the receiver's log lines. Telegram messages must be screenshotted from the chat.
set -u
export MSYS_NO_PATHCONV=1
NGINX=monitoring-3tier-nginx-1; AM=monitoring-3tier-alertmanager-1; PROM=monitoring-3tier-prometheus-1
SINK=monitoring-3tier-alert-sink-1; CHANNEL=${CHANNEL:-webhook}
PORT=${PROMETHEUS_HOST_PORT_UI:-9090}
ts() { date -u +%H:%M:%SZ; }
say() { echo "[$(ts)] $*"; }
prom_alert_state() { curl -s "http://127.0.0.1:$PORT/api/v1/alerts" | python -I -c "
import sys,json
a=[x for x in json.load(sys.stdin)['data']['alerts'] if x['labels']['alertname']=='FrontendDown']
print(a[0]['state'] if a else 'none')"; }
am_active() { docker exec $AM wget -q -O - http://127.0.0.1:9093/api/v2/alerts 2>/dev/null | python -I -c "
import sys,json
print(sum(1 for x in json.load(sys.stdin) if x['labels']['alertname']=='FrontendDown' and x['status']['state']=='active'))"; }
am_counter() { docker exec $AM wget -q -O - http://127.0.0.1:9093/metrics 2>/dev/null | grep "^alertmanager_notifications_$1{integration=\"$CHANNEL\"" | awk '{s+=$2} END{print int(s)}'; }
probe() { curl -s -G "http://127.0.0.1:$PORT/api/v1/query" --data-urlencode 'query=probe_success{job="frontend-blackbox"}' | python -I -c "
import sys,json
r=json.load(sys.stdin)['data']['result']; print(r[0]['value'][1] if r else 'n/a')"; }
wait_for() { # description, command, expected, timeout_s
  i=0; while [ $i -lt $4 ]; do [ "$($2)" = "$3" ] && return 0; sleep 5; i=$((i+5)); done; return 1; }

restore() { say "RESTORE: starting nginx"; docker start $NGINX >/dev/null 2>&1; }
sink_log() { docker logs --since "$1" $SINK 2>&1 | grep FrontendDown | python -I -c "
import sys,json
for l in sys.stdin:
    d=json.loads(l); print('    receiver got:',d['status'].upper(),d['alertname'],'severity='+d['severity'],'startsAt='+d['startsAt'],'endsAt='+d['endsAt'])"; }
case $CHANNEL in
  telegram) docker logs $AM 2>&1 | grep -q "telegram: configured" || { echo "ABORT: Alertmanager has no Telegram credentials (see docs/NIGHT_WATCH_EVIDENCE.md for setup)"; exit 2; } ;;
  webhook)  [ "$(docker inspect -f '{{.State.Health.Status}}' $SINK 2>/dev/null)" = healthy ] || { echo "ABORT: alert-sink is not running/healthy"; exit 2; }
            docker exec $AM wget -q -O - http://127.0.0.1:9093/api/v2/status | grep -q "name: local-webhook" || { echo "ABORT: Alertmanager has not loaded the local-webhook receiver yet (reload/restart Alertmanager)"; exit 2; } ;;
  *) echo "ABORT: CHANNEL must be webhook or telegram"; exit 2 ;;
esac
START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[ "$(prom_alert_state)" = none ] || { echo "ABORT: FrontendDown is not idle at the start"; exit 3; }
[ "$(probe)" = 1 ] || { echo "ABORT: frontend probe is not 1 at the start"; exit 3; }

SENT0=$(am_counter total); FAIL0=$(am_counter failed_total)
say "BASELINE  probe_success=$(probe) FrontendDown=$(prom_alert_state) sent=$SENT0 failed=$FAIL0"
trap restore EXIT INT TERM

say "STEP 1  stopping ONLY $NGINX"
docker stop $NGINX >/dev/null
wait_for "probe 0" probe 0 90 && say "EVIDENCE frontend availability failure: probe_success=0"
wait_for "pending/firing" prom_alert_state firing 240 && say "EVIDENCE alert FIRING in Prometheus: FrontendDown=firing"
wait_for "alertmanager" am_active 1 60 && say "EVIDENCE alert ACTIVE in Alertmanager: FrontendDown (count=$(am_active))"
i=0; while [ $i -lt 120 ] && [ "$(am_counter total)" -le "$SENT0" ]; do sleep 5; i=$((i+5)); done
say "EVIDENCE $CHANNEL firing notification: sent=$(am_counter total) (was $SENT0), failed=$(am_counter failed_total) (was $FAIL0)"
[ "$CHANNEL" = webhook ] && sink_log "$START"
SENT1=$(am_counter total)

say "STEP 2  recovery: starting $NGINX"
docker start $NGINX >/dev/null; trap - EXIT INT TERM
i=0; while [ $i -lt 120 ] && [ "$(docker inspect -f '{{.State.Health.Status}}' $NGINX)" != healthy ]; do sleep 3; i=$((i+3)); done
say "EVIDENCE nginx $(docker inspect -f '{{.State.Health.Status}}' $NGINX)"
wait_for "probe 1" probe 1 90 && say "EVIDENCE frontend recovered: probe_success=1"
wait_for "resolved" prom_alert_state none 120 && say "EVIDENCE alert RESOLVED in Prometheus: FrontendDown=none"
i=0; while [ $i -lt 180 ] && [ "$(am_counter total)" -le "$SENT1" ]; do sleep 5; i=$((i+5)); done
say "EVIDENCE $CHANNEL resolved notification: sent=$(am_counter total) (was $SENT1), failed=$(am_counter failed_total)"
[ "$CHANNEL" = webhook ] && sink_log "$START"
say "FINAL    probe_success=$(probe) FrontendDown=$(prom_alert_state) alertmanager_active=$(am_active) sent=$(am_counter total) failed=$(am_counter failed_total)"
