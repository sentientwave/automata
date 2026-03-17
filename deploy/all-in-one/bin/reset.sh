#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/all-in-one/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd podman

CONFIRM="${1:-}"
if [ "${CONFIRM}" != "--yes" ]; then
  die "Reset is destructive. Re-run with --yes to delete $(volume_name)."
fi

"${SCRIPT_DIR}/stop.sh"

if podman volume exists "$(volume_name)" >/dev/null 2>&1; then
  log "Removing volume $(volume_name)"
  podman volume rm "$(volume_name)" >/dev/null
else
  log "Volume $(volume_name) does not exist"
fi

log "Reset complete"
