#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/all-in-one/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd podman

if ! container_exists; then
  log "Container $(container_name) does not exist"
  exit 0
fi

if container_running; then
  log "Stopping container $(container_name)"
  podman stop "$(container_name)" >/dev/null
fi

log "Removing container $(container_name)"
podman rm "$(container_name)" >/dev/null
log "Container removed"
