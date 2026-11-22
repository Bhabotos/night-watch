#!/usr/bin/env bash
# Runs ON THE VPS (as the non-root deployment user), streamed over SSH by .github/workflows/monitoring-deploy.yml:
#   ssh vps "bash -s -- <git sha> <deploy base dir>" < scripts/deploy_remote.sh
#
# Layout under <deploy base dir>:
#   app/        the live copy of the repository (docker compose runs here). Contains the server-only .env.
#   incoming/   the freshly uploaded repository (staging)
#   backups/    tar.gz of the previous app/ (without .env), the last 5 are kept
#
# Steps: validate incoming with the server's .env -> back up the live copy -> swap -> apply -> health checks.
# On any failure after the swap the previous version is restored automatically and the script exits non-zero.
# It never writes or prints .env, never removes volumes or images, and never runs `down -v` or any prune.
set -euo pipefail

SHA=${1:?usage: deploy_remote.sh <git sha> <deploy base dir>}
BASE=${2:?usage: deploy_remote.sh <git sha> <deploy base dir>}
APP="$BASE/app"; INC="$BASE/incoming"; BK="$BASE/backups"
TS=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="$BK/pre-${TS}-${SHA:0:7}.tgz"
log() { echo "[$(date -u +%H:%M:%SZ)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "refusing to deploy as root"
[ -d "$INC" ] || die "no staging directory $INC (the upload step must run first)"
[ -f "$APP/.env" ] || die "missing $APP/.env: create it once on the server from .env.example; the pipeline never writes it"
mkdir -p "$APP" "$BK"

# Compose needs the server's .env to validate; it is linked in temporarily and never copied into a backup.
log "1/6 validating the uploaded configuration with the server .env"
( cd "$INC" && ln -sf "$APP/.env" .env && docker compose config -q ) || die "docker compose config failed for the new version"
rm -f "$INC/.env"

log "2/6 backing up the current version to $BACKUP"
if [ -f "$APP/docker-compose.yml" ]; then
  tar -czf "$BACKUP" --exclude='.env' -C "$BASE" app
else
  BACKUP=""   # first deployment: nothing to roll back to
  log "     (first deployment, no previous version)"
fi

sync_in() { rsync -a --delete --exclude='.env' "$1/" "$APP/"; }

apply() {
  cd "$APP"
  docker compose up -d --build --wait --wait-timeout 300
  # prometheus.yml, rules and alertmanager.yml are bind-mounted files: reload instead of recreating.
  docker compose kill -s HUP prometheus
  docker compose restart alertmanager
}

healthy() {
  cd "$APP"
  local i out
  for i in $(seq 1 24); do   # up to ~2 minutes for the first scrapes after a reload
    if [ -z "$(docker compose ps --format '{{.Name}} {{.Health}}' | grep -E ' (unhealthy|starting)$' || true)" ]; then
      out=$(docker compose exec -T prometheus wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=count(up%3D%3D0)' 2>/dev/null || true)
      # An empty result means no target has up == 0.
      if echo "$out" | grep -q '"result":\[\]'; then
        docker compose exec -T grafana wget -qO- http://127.0.0.1:3000/api/health 2>/dev/null | grep -q '"database": *"ok"' \
          && docker compose exec -T alertmanager wget -qO- http://127.0.0.1:9093/-/healthy >/dev/null 2>&1 \
          && return 0
      fi
    fi
    sleep 5
  done
  return 1
}

rollback() {
  log "ROLLBACK: restoring the previous version"
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    local tmp; tmp=$(mktemp -d)
    tar -xzf "$BACKUP" -C "$tmp"
    sync_in "$tmp/app"
    rm -rf "$tmp"
    ( apply ) && healthy && log "ROLLBACK complete: previous version is running and healthy" \
      || echo "ROLLBACK FAILED: manual action needed, backup is $BACKUP" >&2
  else
    echo "no previous version to restore (first deployment); stack left as is for inspection" >&2
  fi
}

log "3/6 swapping in the new version"
sync_in "$INC"

log "4/6 applying (compose up, Prometheus reload, Alertmanager restart)"
if ! ( apply ); then rollback; die "applying the new version failed"; fi

log "5/6 health checks (containers healthy, no Prometheus target down, Grafana and Alertmanager up)"
if ! healthy; then rollback; die "health checks failed after deploying ${SHA:0:7}"; fi

log "6/6 pruning old backups (keeping the 5 most recent)"
ls -1t "$BK"/pre-*.tgz 2>/dev/null | tail -n +6 | xargs -r rm -f

log "deployed ${SHA:0:7} successfully"
