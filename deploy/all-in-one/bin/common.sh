#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AIO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${AIO_DIR}/../.." && pwd)"

AIO_ENV_FILE_DEFAULT="${AIO_DIR}/.env"
AIO_IMAGE_DEFAULT="sentientwave-automata:all-in-one"
AIO_CONTAINER_DEFAULT="sentientwave-all-in-one"
AIO_VOLUME_DEFAULT="sw_all_in_one_data"

log() {
  printf '[all-in-one] %s\n' "$*"
}

die() {
  printf '[all-in-one] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

env_file_path() {
  printf '%s\n' "${AIO_ENV_FILE:-${AIO_ENV_FILE_DEFAULT}}"
}

image_tag() {
  printf '%s\n' "${AIO_IMAGE:-${AIO_IMAGE_DEFAULT}}"
}

container_name() {
  printf '%s\n' "${AIO_CONTAINER_NAME:-${AIO_CONTAINER_DEFAULT}}"
}

volume_name() {
  printf '%s\n' "${AIO_VOLUME_NAME:-${AIO_VOLUME_DEFAULT}}"
}

env_get() {
  local key="$1"
  local default_value="$2"
  local file
  local value

  file="$(env_file_path)"
  if [ -f "${file}" ]; then
    value="$(awk -F= -v k="$key" '$1==k {print substr($0, index($0, "=")+1)}' "${file}" | tail -n 1)"
    if [ -n "${value}" ]; then
      printf '%s\n' "${value}"
      return 0
    fi
  fi

  printf '%s\n' "${default_value}"
}

container_exists() {
  local name
  name="$(container_name)"
  podman container exists "${name}" >/dev/null 2>&1
}

container_running() {
  local name
  name="$(container_name)"
  [ "$(podman inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || printf 'false')" = "true" ]
}

ensure_env_file() {
  local file
  file="$(env_file_path)"
  [ -f "${file}" ] || die "Env file not found: ${file}. Run deploy/all-in-one/bin/quickstart.sh first."
}
