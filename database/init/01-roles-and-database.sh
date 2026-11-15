#!/bin/sh
# Runs once, on first initialisation of an empty data directory only.
# Creates the application role/database and the monitoring role.
# Passwords are passed to psql as variables so they are quoted safely.
set -eu

: "${APP_DB_NAME:?}" "${APP_DB_USER:?}" "${APP_DB_PASSWORD:?}"
: "${EXPORTER_DB_USER:?}" "${EXPORTER_DB_PASSWORD:?}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v app_db="$APP_DB_NAME" -v app_user="$APP_DB_USER" -v app_pw="$APP_DB_PASSWORD" \
  -v exp_user="$EXPORTER_DB_USER" -v exp_pw="$EXPORTER_DB_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE :"app_db" OWNER :"app_user";
REVOKE ALL ON DATABASE :"app_db" FROM PUBLIC;
-- Default databases are connectable by everyone; restrict to the admin role.
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;

CREATE ROLE :"exp_user" LOGIN PASSWORD :'exp_pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE;
GRANT pg_monitor TO :"exp_user";
GRANT CONNECT ON DATABASE :"app_db" TO :"exp_user";
SQL

# Extension for query statistics (read by the exporter / dashboards).
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$APP_DB_NAME" \
  -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
