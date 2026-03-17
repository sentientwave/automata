#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/all-in-one/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd podman
ensure_env_file

if container_exists; then
  if container_running; then
    die "Container $(container_name) is already running"
  fi
  log "Removing existing stopped container $(container_name)"
  podman rm "$(container_name)" >/dev/null
fi

PORT="$(env_get PORT 4000)"
POSTGRES_PORT="$(env_get POSTGRES_PORT 5432)"
MATRIX_PORT="$(env_get MATRIX_PORT 8008)"
TEMPORAL_PORT="$(env_get TEMPORAL_PORT 7233)"
TEMPORAL_UI_PORT="$(env_get TEMPORAL_UI_PORT 8233)"
ELEMENT_WEB_PORT="$(env_get ELEMENT_WEB_PORT 8081)"
BIND_HOST="$(env_get AIO_BIND_HOST 0.0.0.0)"

cd "${REPO_ROOT}"
log "Starting container $(container_name)"
podman run -d \
  --name "$(container_name)" \
  --env-file "$(env_file_path)" \
  -p "${BIND_HOST}:${PORT}:${PORT}" \
  -p "${BIND_HOST}:${POSTGRES_PORT}:${POSTGRES_PORT}" \
  -p "${BIND_HOST}:${MATRIX_PORT}:${MATRIX_PORT}" \
  -p "${BIND_HOST}:${ELEMENT_WEB_PORT}:${ELEMENT_WEB_PORT}" \
  -p "${BIND_HOST}:${TEMPORAL_PORT}:${TEMPORAL_PORT}" \
  -p "${BIND_HOST}:${TEMPORAL_UI_PORT}:${TEMPORAL_UI_PORT}" \
  -v "$(volume_name):/data" \
  "$(image_tag)" >/dev/null

log "Container started"
log "Bind host: ${BIND_HOST}"
log "Automata: http://${BIND_HOST}:${PORT}"
log "Matrix:   http://${BIND_HOST}:${MATRIX_PORT}"
log "Element:  http://${BIND_HOST}:${ELEMENT_WEB_PORT}"
log "Temporal: http://${BIND_HOST}:${TEMPORAL_UI_PORT}"
log "Logs:     podman logs -f $(container_name)"
