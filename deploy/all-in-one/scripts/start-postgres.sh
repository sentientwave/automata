#!/usr/bin/env bash
set -euo pipefail

PG_BIN_DIR="${PG_BIN_DIR:-$(pg_config --bindir 2>/dev/null || dirname "$(command -v postgres)")}"
POSTGRES_DATA_DIR="${POSTGRES_DATA_DIR:-/data/postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

exec runuser -u postgres -- "${PG_BIN_DIR}/postgres" \
  -D "${POSTGRES_DATA_DIR}" \
  -p "${POSTGRES_PORT}" \
  -c listen_addresses='0.0.0.0'
