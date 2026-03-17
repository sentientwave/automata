#!/usr/bin/env bash
set -euo pipefail

TEMPORAL_PORT="${TEMPORAL_PORT:-7233}"
TEMPORAL_UI_PORT="${TEMPORAL_UI_PORT:-8233}"
TEMPORAL_DB_FILE="${TEMPORAL_DB_FILE:-/data/temporal/temporal.db}"

mkdir -p "$(dirname "${TEMPORAL_DB_FILE}")"

exec /usr/local/bin/temporal server start-dev \
  --ip 0.0.0.0 \
  --port "${TEMPORAL_PORT}" \
  --ui-port "${TEMPORAL_UI_PORT}" \
  --db-filename "${TEMPORAL_DB_FILE}"
