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
  restart_automata_process "${name}"

  log "Automata hot-upgrade complete (Matrix was not restarted)"
}

restart_automata_process() {
  local name="$1"

  if podman exec "${name}" sh -lc "command -v supervisorctl >/dev/null 2>&1"; then
    if podman exec "${name}" sh -lc "supervisorctl -c /etc/supervisor/conf.d/all-in-one.conf restart automata"; then
      return 0
    fi

    log "supervisorctl exists but restart failed; trying direct process recycle"
  else
    log "supervisorctl not available; trying direct process recycle"
  fi

  podman exec "${name}" sh -lc '
set -eu

beam_before="$(pgrep -f "beam.smp.*(phx.server|sentientwave_automata)" | head -n 1 || true)"

# Stop Automata processes as safely as possible. Keep Matrix untouched.
for p in $(pgrep -f "(beam.smp.*(phx.server|sentientwave_automata)|/opt/all-in-one/scripts/start-automata.sh|mix phx.server)" || true); do
  [ -n "$p" ] && kill -TERM "$p" || true
done

sleep 2

if pgrep -x supervisord >/dev/null 2>&1; then
  # Wait for supervisord to respawn Automata.
  i=0
  while [ "$i" -lt 20 ]; do
    beam_after="$(pgrep -f "beam.smp.*(phx.server|sentientwave_automata)" | head -n 1 || true)"
    if [ -n "$beam_after" ] && [ "$beam_after" != "$beam_before" ]; then
      exit 0
    fi
    i=$((i+1))
    sleep 1
  done
else
  # No supervisor in container; start Automata in background.
  nohup /opt/all-in-one/scripts/start-automata.sh >/tmp/automata-upgrade.log 2>&1 &
  sleep 2
  if pgrep -f "beam.smp.*(phx.server|sentientwave_automata)" >/dev/null 2>&1; then
    exit 0
  fi
fi

echo "[all-in-one] ERROR: Unable to verify Automata restart after upgrade" >&2
exit 1
'
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
