#!/bin/sh
# Phase 2 checks. Run from the repo root with the stack up: sh tests/e2e/check_phase2.sh
set -u
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
set -a; . ./.env; set +a
C=monitoring-3tier-postgres-1
q() { docker exec -e PGPASSWORD="$2" "$C" psql -h 127.0.0.1 -U "$1" -d "$3" -Atc "$4" 2>&1; }

[ "$(docker inspect -f '{{.State.Health.Status}}' $C)" = healthy ] && ok "container healthy" || bad "container healthy"
[ -z "$(docker inspect -f '{{json .NetworkSettings.Ports}}' $C | grep -o 'HostPort' )" ] && ok "no host port published" || bad "no host port published"
[ "$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' $C)" = "monitoring-3tier_application " ] && ok "attached to application network only" || bad "network attachment"
[ "$(docker network inspect -f '{{.Internal}}' monitoring-3tier_application)" = true ] && ok "application network is internal" || bad "application network internal"
[ "$(q "$APP_DB_USER" "$APP_DB_PASSWORD" "$APP_DB_NAME" 'select 1')" = 1 ] && ok "app role can connect" || bad "app role can connect"
[ "$(q "$APP_DB_USER" "$APP_DB_PASSWORD" "$APP_DB_NAME" 'select rolsuper from pg_roles where rolname=current_user')" = f ] && ok "app role is not superuser" || bad "app role is not superuser"
[ "$(q "$EXPORTER_DB_USER" "$EXPORTER_DB_PASSWORD" "$APP_DB_NAME" "select pg_has_role(current_user,'pg_monitor','member')")" = t ] && ok "exporter role has pg_monitor" || bad "exporter role has pg_monitor"
[ "$(q "$EXPORTER_DB_USER" "$EXPORTER_DB_PASSWORD" "$APP_DB_NAME" 'create table t(i int)' | grep -c 'permission denied')" = 1 ] && ok "exporter role cannot create tables" || bad "exporter role cannot create tables"
q "$APP_DB_USER" "$APP_DB_PASSWORD" postgres 'select 1' | grep -q 'permission denied' && ok "app role cannot connect to postgres db" || bad "app role isolated from postgres db"
q "$APP_DB_USER" wrong "$APP_DB_NAME" 'select 1' | grep -q 'authentication failed' && ok "wrong password rejected (scram)" || bad "wrong password rejected"
[ "$(q "$POSTGRES_ADMIN_USER" "$POSTGRES_ADMIN_PASSWORD" "$APP_DB_NAME" "select count(*) from pg_extension where extname='pg_stat_statements'")" = 1 ] && ok "pg_stat_statements enabled" || bad "pg_stat_statements"
[ "$(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' $C)" = true ] && ok "read-only root filesystem" || bad "read-only rootfs"
exit $fail
