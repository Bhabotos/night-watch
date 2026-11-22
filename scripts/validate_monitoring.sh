#!/bin/sh
# Validates the monitoring configuration. Used by GitHub Actions (every pull request, and before every deploy)
# and runnable locally from the repo root:  sh scripts/validate_monitoring.sh
#
# Needs only Docker (the same pinned images as docker-compose.yml are used for promtool, amtool and blackbox)
# and Python 3 with the standard library. It never touches running containers or the network of the stack.
# Exit code 0 = everything valid, 1 = at least one check failed.
set -u
export MSYS_NO_PATHCONV=1
ROOT=$(pwd -W 2>/dev/null || pwd)   # a Windows path under Git Bash, the normal path on Linux
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
check() { if eval "$2" >/tmp/nw_check.out 2>&1; then ok "$1"; else bad "$1"; sed 's/^/        /' /tmp/nw_check.out | tail -12; fi; }

PY=$(for p in python3 python; do command -v "$p" >/dev/null 2>&1 && "$p" -c "" >/dev/null 2>&1 && { echo "$p"; break; }; done)
[ -n "$PY" ] || { echo "FAIL  python 3 not found"; exit 1; }
image() { grep -m1 -oE "image: *$1[^ ]*" docker-compose.yml | sed 's/image: *//'; }   # pinned tag from the compose file
PROM=$(image 'prom/prometheus'); AM=$(image 'prom/alertmanager'); BB=$(image 'prom/blackbox-exporter')
[ -n "$PROM" ] && [ -n "$AM" ] && [ -n "$BB" ] || { echo "FAIL  could not read the pinned images from docker-compose.yml"; exit 1; }
echo "images: $PROM $AM $BB"

echo "== Docker Compose"
# .env.example holds placeholders only, so no secrets are needed to validate the file.
check "docker compose config is valid (placeholders from .env.example)" "docker compose --env-file .env.example config -q"

echo "== Prometheus"
check "promtool check config (prometheus.yml and the rule files it loads)" \
  "docker run --rm --entrypoint promtool -v '$ROOT/monitoring/prometheus:/etc/prometheus:ro' $PROM check config /etc/prometheus/prometheus.yml"
check "promtool check rules (alerts.yml, recording.yml)" \
  "docker run --rm --entrypoint promtool -v '$ROOT/monitoring/prometheus/rules:/rules:ro' $PROM check rules /rules/alerts.yml /rules/recording.yml"
for t in tests/prometheus/*_test.yml; do
  check "promtool test rules $(basename "$t")" \
    "docker run --rm --entrypoint promtool -v '$ROOT:/w:ro' -w /w/tests/prometheus $PROM test rules $(basename "$t")"
done

echo "== Alertmanager and Blackbox Exporter"
check "amtool check-config alertmanager.yml" \
  "docker run --rm --entrypoint amtool -v '$ROOT/monitoring/alertmanager/alertmanager.yml:/a.yml:ro' $AM check-config /a.yml"
check "blackbox_exporter --config.check blackbox.yml" \
  "docker run --rm -v '$ROOT/monitoring/blackbox/blackbox.yml:/b.yml:ro' $BB --config.file=/b.yml --config.check"

echo "== Grafana dashboards"
for f in $(find monitoring/grafana -name '*.json' | sort); do
  check "valid JSON: $f" "$PY -X utf8 -m json.tool $f"
done
check "dashboard lint (titles, uids, units, datasources, no secrets)" "$PY -I tests/e2e/dashboards_lint.py"
check "dashboard regression tests (required dashboards, 6+ panels, 3+ visualization types, rows per tier)" \
  "$PY -I -m unittest discover -s tests/e2e -p 'test_*.py'"

echo "== Pipeline guard rails and secrets"
check "workflow safety tests (PR validation, deploy only from main after validation)" \
  "$PY -I -m unittest discover -s tests/ci -p 'test_*.py'"
check ".env is not tracked by git" "! git ls-files --error-unmatch .env"
check "no Telegram bot token or private key in tracked files" \
  "! git grep --untracked -nE '[0-9]{8,10}:[A-Za-z0-9_-]{35}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY' -- . ':!.gitleaksignore'"

echo
if [ "$fail" = 0 ]; then echo "RESULT: all validation checks passed"; else echo "RESULT: validation FAILED"; fi
exit $fail
