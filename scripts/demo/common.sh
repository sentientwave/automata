#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[demo] missing required command: $cmd" >&2
    exit 1
  fi
}

trim() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

demo_root_dir() {
  cd "$(dirname "${BASH_SOURCE[0]}")/../.." >/dev/null 2>&1
  pwd
}

slugify() {
  local input="$1"
  printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/--+/-/g'
}

derive_room_alias_localpart() {
  local company_name="$1"
  local group_name="$2"
  local company_slug
  local group_slug
  company_slug="$(slugify "$company_name")"
  group_slug="$(slugify "$group_name")"
  printf '%s-%s-automata' "$company_slug" "$group_slug" | sed -E 's/--+/-/g; s/^-+//; s/-+$//'
}

normalize_mxid() {
  local value="$1"
  local domain="$2"

  if [[ "$value" == @*:* ]]; then
    printf '%s' "$value"
  elif [[ "$value" == @* ]]; then
    printf '%s:%s' "$value" "$domain"
  else
    printf '@%s:%s' "$value" "$domain"
  fi
}

wait_for_http() {
  local name="$1"
  local url="$2"
  local timeout_seconds="$3"

  local deadline=$((SECONDS + timeout_seconds))
  while ((SECONDS < deadline)); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "[demo] ${name} check failed: ${url}" >&2
  return 1
}

build_invites_csv() {
  local users_csv="$1"
  local domain="$2"

  printf '%s' "$users_csv" |
    tr ',' '\n' |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' |
    awk 'NF' |
    while IFS= read -r user; do
      normalize_mxid "$user" "$domain"
      printf '\n'
    done |
    paste -sd ',' -
}

build_onboarding_payload() {
  local company_key="$1"
  local company_name="$2"
  local admin_mxid="$3"
  local homeserver="$4"
  local group_key="$5"
  local group_name="$6"
  local group_visibility="$7"
  local group_auto_join="$8"
  local invites_csv="$9"

  jq -nc \
    --arg company_key "$company_key" \
    --arg company_name "$company_name" \
    --arg admin_user_id "$admin_mxid" \
    --arg homeserver "$homeserver" \
    --arg group_key "$group_key" \
    --arg group_name "$group_name" \
    --arg group_visibility "$group_visibility" \
    --arg invites "$invites_csv" \
    --argjson auto_join "$group_auto_join" \
    '{
      company: {
        key: $company_key,
        name: $company_name,
        admin_user_id: $admin_user_id,
        homeserver: $homeserver
      },
      group: {
        key: $group_key,
        name: $group_name,
        visibility: $group_visibility,
        auto_join: $auto_join
      },
      invites: $invites
    }'
}

post_onboarding_validate() {
  local automata_url="$1"
  local payload="$2"

  curl -fsS -X POST "${automata_url}/api/v1/onboarding/validate" \
    -H 'content-type: application/json' \
    -d "$payload"
}

load_demo_defaults() {
  local root
  local aio_env_file

  root="$(demo_root_dir)"
  aio_env_file="${AIO_ENV_FILE:-${root}/deploy/all-in-one/.env}"

  env_file_get() {
    local key="$1"
    local fallback="$2"
    local value=""

    if [ -f "$aio_env_file" ]; then
      value="$(awk -F= -v k="$key" '$1==k {print substr($0, index($0, "=")+1)}' "$aio_env_file" | tail -n 1)"
    fi

    if [ -n "$value" ]; then
      printf '%s' "$value"
    else
      printf '%s' "$fallback"
    fi
  }

  DEMO_AUTOMATA_URL="${DEMO_AUTOMATA_URL:-http://localhost:4000}"
  DEMO_MATRIX_URL="${DEMO_MATRIX_URL:-http://localhost:8008}"
  DEMO_TEMPORAL_UI_URL="${DEMO_TEMPORAL_UI_URL:-http://localhost:8233}"
  DEMO_WAIT_SECONDS="${DEMO_WAIT_SECONDS:-45}"

  DEMO_COMPANY_KEY="${DEMO_COMPANY_KEY:-$(env_file_get COMPANY_NAME sentientwave | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')}"
  DEMO_COMPANY_NAME="${DEMO_COMPANY_NAME:-$(env_file_get COMPANY_NAME SentientWave)}"
  DEMO_GROUP_KEY="${DEMO_GROUP_KEY:-$(env_file_get GROUP_NAME 'core-team' | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')}"
  DEMO_GROUP_NAME="${DEMO_GROUP_NAME:-$(env_file_get GROUP_NAME 'Core Team')}"

  DEMO_MATRIX_HOMESERVER_DOMAIN="${DEMO_MATRIX_HOMESERVER_DOMAIN:-$(env_file_get MATRIX_HOMESERVER_DOMAIN localhost)}"
  DEMO_MATRIX_ADMIN_USER="${DEMO_MATRIX_ADMIN_USER:-$(env_file_get MATRIX_ADMIN_USER admin)}"
  DEMO_MATRIX_ADMIN_PASSWORD="${DEMO_MATRIX_ADMIN_PASSWORD:-$(env_file_get MATRIX_ADMIN_PASSWORD change-this)}"
  DEMO_USERS="${DEMO_USERS:-$(env_file_get MATRIX_INVITE_USERS 'alice,bob')}"
  DEMO_INVITE_PASSWORD="${DEMO_INVITE_PASSWORD:-$(env_file_get MATRIX_INVITE_PASSWORD changeme123)}"

  DEMO_GROUP_VISIBILITY="${DEMO_GROUP_VISIBILITY:-private}"
  DEMO_GROUP_AUTO_JOIN="${DEMO_GROUP_AUTO_JOIN:-true}"
}
