#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/all-in-one/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd podman

if ! container_exists; then
  die "Container $(container_name) does not exist"
fi

log "Container status"
podman ps -a --filter "name=$(container_name)"

PORT="$(env_get PORT 4000)"
MATRIX_PORT="$(env_get MATRIX_PORT 8008)"
TEMPORAL_UI_PORT="$(env_get TEMPORAL_UI_PORT 8233)"

printf '\nHealth checks\n'
if curl -fsS "http://localhost:${PORT}/" >/dev/null 2>&1; then
  printf '  - Automata: OK\n'
else
  printf '  - Automata: NOT READY\n'
fi

if curl -fsS "http://localhost:${MATRIX_PORT}/_matrix/client/versions" >/dev/null 2>&1; then
  printf '  - Matrix: OK\n'
else
  printf '  - Matrix: NOT READY\n'
fi

if curl -fsS "http://localhost:${TEMPORAL_UI_PORT}/" >/dev/null 2>&1; then
  printf '  - Temporal UI: OK\n'
else
  printf '  - Temporal UI: NOT READY\n'
fi

printf '\nConnection summary\n'
podman exec "$(container_name)" sh -lc 'cat /data/connection-info.txt 2>/dev/null || echo "connection-info.txt not ready yet"'
