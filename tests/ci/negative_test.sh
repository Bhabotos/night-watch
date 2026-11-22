#!/bin/sh
# Proves the validation really fails on broken configuration. It works on a throw-away COPY of the repo
# (in a temp directory), so nothing in the real repository, the running stack or Git is changed.
#
#   sh tests/ci/negative_test.sh
#
# 1 control run on the unmodified copy must PASS, then each fault below must make scripts/validate_monitoring.sh FAIL.
# The same faults, committed on a temporary branch, are what produces the "failed run" screenshot on GitHub.
set -u
export MSYS_NO_PATHCONV=1
SRC=$(pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
status=0

fresh_copy() {
  rm -rf "$WORK/repo"; mkdir -p "$WORK/repo"
  for p in docker-compose.yml .env.example monitoring tests scripts .github; do cp -R "$SRC/$p" "$WORK/repo/"; done
}

run_validation() { ( cd "$WORK/repo" && sh scripts/validate_monitoring.sh ) > "$WORK/out.txt" 2>&1; }

expect() { # name, expected exit (0 pass, 1 fail)
  run_validation; got=$?
  if [ "$got" = "$2" ]; then echo "PASS  $1 (validation exit $got, as expected)"
  else echo "FAIL  $1 (validation exit $got, expected $2)"; sed 's/^/      /' "$WORK/out.txt" | tail -15; status=1; fi
  [ "$2" = 1 ] && grep -E "^FAIL " "$WORK/out.txt" | head -3 | sed 's/^/        caught by: /'
}

fresh_copy;                                                                              expect "control: unmodified configuration passes" 0

fresh_copy; sed -i 's/expr: up{job="backend"} == 0/expr: up{job="backend" == 0/' "$WORK/repo/monitoring/prometheus/rules/alerts.yml"
expect "fault 1: invalid PromQL in an alert rule" 1

fresh_copy; sed -i 's/^  scrape_interval: 15s/  scrape_interval: fifteen-seconds/' "$WORK/repo/monitoring/prometheus/prometheus.yml"
expect "fault 2: invalid scrape_interval in prometheus.yml" 1

fresh_copy; sed -i 's/^  receiver: telegram/  receiver: does-not-exist/' "$WORK/repo/monitoring/alertmanager/alertmanager.yml"
expect "fault 3: Alertmanager route points to an unknown receiver" 1

fresh_copy; head -c 2000 "$WORK/repo/monitoring/grafana/dashboards/night-watch/three-tier-production.json" > "$WORK/t.json" \
  && mv "$WORK/t.json" "$WORK/repo/monitoring/grafana/dashboards/night-watch/three-tier-production.json"
expect "fault 4: truncated (invalid) dashboard JSON" 1

fresh_copy; sed -i 's/\("title": "Three-Tier App\)[^"]*"/\1"/' "$WORK/repo/monitoring/grafana/dashboards/night-watch/three-tier-production.json"
grep -q '"title": "Three-Tier App"' "$WORK/repo/monitoring/grafana/dashboards/night-watch/three-tier-production.json" || { echo "FAIL  fault 5 could not be applied"; exit 1; }
expect "fault 5: dashboard renamed (valid JSON, requirement broken)" 1

[ $status = 0 ] && echo "RESULT: validation passes on valid config and fails on every injected fault" || echo "RESULT: negative test FAILED"
exit $status
