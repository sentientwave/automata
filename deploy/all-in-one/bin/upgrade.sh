#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/all-in-one/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd podman
ensure_env_file

SKIP_BUILD=0
FULL_STACK=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --full-stack) FULL_STACK=1 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

hot_upgrade_automata() {
  local name
  name="$(container_name)"

  if ! container_running; then
    die "Container ${name} is not running. Use --full-stack or run deploy/all-in-one/bin/run.sh first."
  fi

  log "Hot-upgrading Automata in running container ${name} (Matrix stays online)"

  # Clean accidental nested copies from previous runs, then sync source tree.
  podman exec "${name}" sh -lc "rm -rf /app/apps/apps /app/config/config"
  podman cp "${REPO_ROOT}/mix.exs" "${name}:/app/mix.exs"
  podman cp "${REPO_ROOT}/mix.lock" "${name}:/app/mix.lock"
  podman cp "${REPO_ROOT}/config/." "${name}:/app/config"
  podman cp "${REPO_ROOT}/apps/." "${name}:/app/apps"

  podman exec "${name}" sh -lc "cd /app && MIX_ENV=prod mix deps.get && mix assets.deploy && mix compile"
  if ! podman exec "${name}" supervisorctl restart automata >/dev/null 2>&1; then
    log "supervisorctl unavailable in running container; falling back to process restart for automata"
    podman exec "${name}" sh -lc "for p in \$(pgrep -f '[b]eam.smp.*sentientwave_automata' || true); do [ -n \"\$p\" ] && kill -TERM \"\$p\" || true; done; exit 0"
  fi

  log "Automata hot-upgrade complete (Matrix was not restarted)"
}

full_stack_upgrade() {
  if [ "$SKIP_BUILD" -eq 0 ]; then
    log "Building latest image before full-stack upgrade"
    "${SCRIPT_DIR}/build.sh"
  else
    log "Skipping image build due to --skip-build"
  fi

  if container_exists; then
    if container_running; then
      log "Stopping running container $(container_name)"
      podman stop "$(container_name)" >/dev/null
    fi

    log "Removing old container $(container_name)"
    podman rm "$(container_name)" >/dev/null
  fi

  log "Starting upgraded container using existing data volume $(volume_name)"
  "${SCRIPT_DIR}/run.sh"
  log "Full-stack upgrade complete (container replaced)"
}

if [ "$FULL_STACK" -eq 1 ]; then
  full_stack_upgrade
else
  hot_upgrade_automata
fi
