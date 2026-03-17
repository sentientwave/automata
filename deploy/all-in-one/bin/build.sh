#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/all-in-one/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd podman

cd "${REPO_ROOT}"
log "Building image $(image_tag) from deploy/all-in-one/Dockerfile"
podman build \
  -f deploy/all-in-one/Dockerfile \
  -t "$(image_tag)" \
  .

log "Build complete"
