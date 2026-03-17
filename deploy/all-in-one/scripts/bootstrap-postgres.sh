#!/usr/bin/env bash
set -euo pipefail

PG_BIN_DIR="${PG_BIN_DIR:-$(pg_config --bindir 2>/dev/null || dirname "$(command -v postgres)")}"
POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-/data/postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
PGVECTOR_REQUIRED="${PGVECTOR_REQUIRED:-false}"

mkdir -p "${POSTGRES_DATA_DIR}" /data/logs
chown -R postgres:postgres "${POSTGRES_DATA_DIR}" /data/logs

if [ ! -s "${POSTGRES_DATA_DIR}/PG_VERSION" ]; then
  echo "[bootstrap-postgres] initializing new PostgreSQL data directory"
  runuser -u postgres -- "${PG_BIN_DIR}/initdb" -D "${POSTGRES_DATA_DIR}" --encoding=UTF8 --locale=C
fi

echo "[bootstrap-postgres] starting temporary PostgreSQL"
runuser -u postgres -- "${PG_BIN_DIR}/pg_ctl" -D "${POSTGRES_DATA_DIR}" \
  -l /data/logs/postgres-bootstrap.log \
  -o "-p ${POSTGRES_PORT} -c listen_addresses=127.0.0.1" \
  -w start

runuser -u postgres -- "${PG_BIN_DIR}/psql" -v ON_ERROR_STOP=1 -p "${POSTGRES_PORT}" postgres <<SQL
ALTER USER postgres WITH PASSWORD '${POSTGRES_PASSWORD}';

DO
\$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${APP_DB_USER}') THEN
    EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', '${APP_DB_USER}', '${APP_DB_PASSWORD}');
  END IF;
END
\$\$;

SELECT format('CREATE DATABASE %I OWNER %I', '${APP_DB_NAME}', '${APP_DB_USER}')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${APP_DB_NAME}')
\gexec
SQL

if [ "${PGVECTOR_REQUIRED}" = "true" ]; then
  if runuser -u postgres -- "${PG_BIN_DIR}/psql" -v ON_ERROR_STOP=1 -p "${POSTGRES_PORT}" "${APP_DB_NAME}" \
    -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1; then
    echo "[bootstrap-postgres] pgvector extension ensured on ${APP_DB_NAME}"
  else
    echo "[bootstrap-postgres] ERROR: pgvector extension unavailable and PGVECTOR_REQUIRED=true" >&2
    runuser -u postgres -- "${PG_BIN_DIR}/pg_ctl" -D "${POSTGRES_DATA_DIR}" -m fast -w stop
    exit 1
  fi
else
  echo "[bootstrap-postgres] pgvector bootstrap skipped (PGVECTOR_REQUIRED=${PGVECTOR_REQUIRED})"
fi

echo "[bootstrap-postgres] stopping temporary PostgreSQL"
runuser -u postgres -- "${PG_BIN_DIR}/pg_ctl" -D "${POSTGRES_DATA_DIR}" -m fast -w stop
