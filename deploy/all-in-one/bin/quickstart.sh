#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/all-in-one/bin/common.sh
source "${SCRIPT_DIR}/common.sh"

require_cmd podman
require_cmd openssl

ENV_ONLY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --env-only) ENV_ONLY=1 ;;
    --force) FORCE=1 ;;
    *) die "Unknown argument: $arg" ;;
  esac
done

prompt_value() {
  local prompt="$1"
  local default_value="$2"
  local current

  if [ "$FORCE" -eq 1 ]; then
    printf '%s\n' "$default_value"
    return 0
  fi

  read -r -p "${prompt} [${default_value}]: " current
  if [ -z "$current" ]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$current"
  fi
}

prompt_secret() {
  local prompt="$1"
  local default_value="$2"
  local current

  if [ "$FORCE" -eq 1 ]; then
    printf '%s\n' "$default_value"
    return 0
  fi

  read -r -s -p "${prompt} [hidden]: " current
  printf '\n' >&2
  if [ -z "$current" ]; then
    printf '%s\n' "$default_value"
  else
    printf '%s\n' "$current"
  fi
}

set_kv() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp

  tmp="$(mktemp)"
  awk -F= -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    $1 == k {
      print k "=" v
      done = 1
      next
    }
    { print }
    END {
      if (done == 0) {
        print k "=" v
      }
    }
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}

ENV_FILE="$(env_file_path)"
TEMPLATE_FILE="${AIO_DIR}/env.template"

if [ ! -f "${TEMPLATE_FILE}" ]; then
  die "Missing template: ${TEMPLATE_FILE}"
fi

if [ -f "${ENV_FILE}" ] && [ "$FORCE" -ne 1 ]; then
  read -r -p "${ENV_FILE} exists. Overwrite? [y/N]: " overwrite
  case "$overwrite" in
    y|Y|yes|YES) ;;
    *) die "Aborted to avoid overwriting existing env file" ;;
  esac
fi

SECRET_KEY_BASE="$(openssl rand -hex 64)"
MATRIX_ADMIN_PASSWORD_DEFAULT="$(openssl rand -hex 12)"
MATRIX_INVITE_PASSWORD_DEFAULT="$(openssl rand -hex 8)"

PHX_HOST="$(prompt_value 'Phoenix host' 'localhost')"
COMPANY_NAME="$(prompt_value 'Company name' 'SentientWave')"
GROUP_NAME="$(prompt_value 'Group name' 'Core Team')"
MATRIX_SERVER_NAME="$(prompt_value 'Matrix server name' 'localhost')"
MATRIX_HOMESERVER_DOMAIN="$(prompt_value 'Matrix homeserver domain' "${MATRIX_SERVER_NAME}")"
MATRIX_ADMIN_USER="$(prompt_value 'Matrix admin username (without @domain)' 'admin')"
MATRIX_ADMIN_PASSWORD="$(prompt_secret 'Matrix admin password' "${MATRIX_ADMIN_PASSWORD_DEFAULT}")"
MATRIX_INVITE_USERS="$(prompt_value 'Invite users (comma-separated localparts)' 'alice,bob')"
MATRIX_INVITE_PASSWORD="$(prompt_secret 'Invite user password' "${MATRIX_INVITE_PASSWORD_DEFAULT}")"
AUTOMATA_LLM_PROVIDER="$(prompt_value 'LLM provider (local/openai/gemini/openrouter/lm-studio/ollama)' 'local')"

case "${AUTOMATA_LLM_PROVIDER}" in
  openai)
    AUTOMATA_LLM_MODEL_DEFAULT="gpt-5.4"
    AUTOMATA_LLM_BASE_DEFAULT="https://api.openai.com/v1"
    ;;
  gemini)
    AUTOMATA_LLM_MODEL_DEFAULT="gemini-3.1-pro-preview"
    AUTOMATA_LLM_BASE_DEFAULT="https://generativelanguage.googleapis.com/v1beta"
    ;;
  openrouter)
    AUTOMATA_LLM_MODEL_DEFAULT="openrouter/auto"
    AUTOMATA_LLM_BASE_DEFAULT="https://openrouter.ai/api/v1"
    ;;
  lm-studio)
    AUTOMATA_LLM_MODEL_DEFAULT="local-model"
    AUTOMATA_LLM_BASE_DEFAULT="http://host.containers.internal:1234/v1"
    ;;
  ollama)
    AUTOMATA_LLM_MODEL_DEFAULT="llama3.1"
    AUTOMATA_LLM_BASE_DEFAULT="http://host.containers.internal:11434"
    ;;
  *)
    AUTOMATA_LLM_PROVIDER="local"
    AUTOMATA_LLM_MODEL_DEFAULT="local-default"
    AUTOMATA_LLM_BASE_DEFAULT=""
    ;;
esac

AUTOMATA_LLM_MODEL="$(prompt_value 'LLM model' "${AUTOMATA_LLM_MODEL_DEFAULT}")"
AUTOMATA_LLM_API_BASE="$(prompt_value 'LLM base URL (blank for provider default)' "${AUTOMATA_LLM_BASE_DEFAULT}")"

if [ "${AUTOMATA_LLM_PROVIDER}" = "local" ]; then
  AUTOMATA_LLM_API_KEY=""
else
  AUTOMATA_LLM_API_KEY="$(prompt_secret 'LLM API key/token (optional for local endpoints)' '')"
fi

cp "${TEMPLATE_FILE}" "${ENV_FILE}"
set_kv "${ENV_FILE}" "PHX_HOST" "${PHX_HOST}"
set_kv "${ENV_FILE}" "SECRET_KEY_BASE" "${SECRET_KEY_BASE}"
set_kv "${ENV_FILE}" "COMPANY_NAME" "${COMPANY_NAME}"
set_kv "${ENV_FILE}" "GROUP_NAME" "${GROUP_NAME}"
set_kv "${ENV_FILE}" "MATRIX_SERVER_NAME" "${MATRIX_SERVER_NAME}"
set_kv "${ENV_FILE}" "MATRIX_HOMESERVER_DOMAIN" "${MATRIX_HOMESERVER_DOMAIN}"
set_kv "${ENV_FILE}" "MATRIX_ADMIN_USER" "${MATRIX_ADMIN_USER}"
set_kv "${ENV_FILE}" "MATRIX_ADMIN_PASSWORD" "${MATRIX_ADMIN_PASSWORD}"
set_kv "${ENV_FILE}" "AUTOMATA_WEB_ADMIN_USER" "${MATRIX_ADMIN_USER}"
set_kv "${ENV_FILE}" "AUTOMATA_WEB_ADMIN_PASSWORD" "${MATRIX_ADMIN_PASSWORD}"
set_kv "${ENV_FILE}" "MATRIX_INVITE_USERS" "${MATRIX_INVITE_USERS}"
set_kv "${ENV_FILE}" "MATRIX_INVITE_PASSWORD" "${MATRIX_INVITE_PASSWORD}"
set_kv "${ENV_FILE}" "MATRIX_AGENT_USER" "automata"
set_kv "${ENV_FILE}" "MATRIX_AGENT_PASSWORD" "${MATRIX_INVITE_PASSWORD}"
set_kv "${ENV_FILE}" "AUTOMATA_AGENT_USERS" "automata"
set_kv "${ENV_FILE}" "AUTOMATA_AGENT_PASSWORD" "${MATRIX_INVITE_PASSWORD}"
set_kv "${ENV_FILE}" "MATRIX_MAIN_ROOM_NAME" "Main"
set_kv "${ENV_FILE}" "MATRIX_MAIN_ROOM_ALIAS" "main"
set_kv "${ENV_FILE}" "MATRIX_RANDOM_ROOM_NAME" "Random"
set_kv "${ENV_FILE}" "MATRIX_RANDOM_ROOM_ALIAS" "random"
set_kv "${ENV_FILE}" "ELEMENT_WEB_PORT" "8081"
set_kv "${ENV_FILE}" "ELEMENT_DEFAULT_HOMESERVER_URL" "http://${MATRIX_SERVER_NAME}:8008"
set_kv "${ENV_FILE}" "ELEMENT_DEFAULT_SERVER_NAME" "${MATRIX_HOMESERVER_DOMAIN}"
set_kv "${ENV_FILE}" "AUTOMATA_LLM_PROVIDER" "${AUTOMATA_LLM_PROVIDER}"
set_kv "${ENV_FILE}" "AUTOMATA_LLM_MODEL" "${AUTOMATA_LLM_MODEL}"
set_kv "${ENV_FILE}" "AUTOMATA_LLM_API_BASE" "${AUTOMATA_LLM_API_BASE}"
set_kv "${ENV_FILE}" "AUTOMATA_LLM_API_KEY" "${AUTOMATA_LLM_API_KEY}"

log "Wrote env file: ${ENV_FILE}"

if [ "$ENV_ONLY" -eq 1 ]; then
  log "Skipping build/run due to --env-only"
  exit 0
fi

"${SCRIPT_DIR}/build.sh"
"${SCRIPT_DIR}/run.sh"
