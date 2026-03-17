#!/usr/bin/env bash
set -euo pipefail

POSTGRES_PORT="${POSTGRES_PORT:-5432}"
APP_DB_USER="${APP_DB_USER:-automata}"
APP_DB_PASSWORD="${APP_DB_PASSWORD:-automata}"
APP_DB_NAME="${APP_DB_NAME:-sentientwave_dev}"
export MIX_ENV="${MIX_ENV:-prod}"
export PHX_HOST="${PHX_HOST:-localhost}"
export PORT="${PORT:-4000}"
export SECRET_KEY_BASE="${SECRET_KEY_BASE:-insecure_dev_only_change_me}"
export DATABASE_URL="${DATABASE_URL:-ecto://${APP_DB_USER}:${APP_DB_PASSWORD}@127.0.0.1:${POSTGRES_PORT}/${APP_DB_NAME}}"
export PGVECTOR_REQUIRED="${PGVECTOR_REQUIRED:-false}"
export AUTOMATA_SKILLS_PATH="${AUTOMATA_SKILLS_PATH:-/data/skills}"
export AUTOMATA_EMBEDDING_PROVIDER="${AUTOMATA_EMBEDDING_PROVIDER:-local}"
export AUTOMATA_EMBEDDING_MODEL="${AUTOMATA_EMBEDDING_MODEL:-sentence-transformers/all-MiniLM-L6-v2}"
export AUTOMATA_EMBEDDING_API_BASE="${AUTOMATA_EMBEDDING_API_BASE:-}"
export AUTOMATA_EMBEDDING_API_KEY="${AUTOMATA_EMBEDDING_API_KEY:-}"
export AUTOMATA_LLM_PROVIDER="${AUTOMATA_LLM_PROVIDER:-local}"
export AUTOMATA_LLM_MODEL="${AUTOMATA_LLM_MODEL:-local-default}"
export AUTOMATA_LLM_API_BASE="${AUTOMATA_LLM_API_BASE:-}"
export AUTOMATA_LLM_API_KEY="${AUTOMATA_LLM_API_KEY:-}"
export AUTOMATA_LLM_TIMEOUT_MS="${AUTOMATA_LLM_TIMEOUT_MS:-30000}"
export AUTOMATA_LLM_CONNECT_TIMEOUT_MS="${AUTOMATA_LLM_CONNECT_TIMEOUT_MS:-3000}"
export AUTOMATA_TEMPORAL_TASK_QUEUE="${AUTOMATA_TEMPORAL_TASK_QUEUE:-automata-agents}"

until PGPASSWORD="${APP_DB_PASSWORD}" pg_isready -h 127.0.0.1 -p "${POSTGRES_PORT}" -U "${APP_DB_USER}" -d "${APP_DB_NAME}" >/dev/null 2>&1; do
  echo "[automata] waiting for postgres at 127.0.0.1:${POSTGRES_PORT}"
  sleep 2
done

if [ "${PGVECTOR_REQUIRED}" = "true" ]; then
  if ! PGPASSWORD="${APP_DB_PASSWORD}" psql -h 127.0.0.1 -p "${POSTGRES_PORT}" -U "${APP_DB_USER}" -d "${APP_DB_NAME}" -tAc "SELECT 1 FROM pg_extension WHERE extname='vector'" | grep -q 1; then
    echo "[automata] ERROR: pgvector extension not available in ${APP_DB_NAME}" >&2
    exit 1
  fi
else
  echo "[automata] pgvector preflight skipped (PGVECTOR_REQUIRED=${PGVECTOR_REQUIRED})"
fi

mix ecto.create || true
mix ecto.migrate

exec mix phx.server
