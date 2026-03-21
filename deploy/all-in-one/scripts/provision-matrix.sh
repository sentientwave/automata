#!/usr/bin/env bash
set -euo pipefail

MATRIX_PORT="${MATRIX_PORT:-8008}"
MATRIX_SERVER_NAME="${MATRIX_SERVER_NAME:-localhost}"
MATRIX_HOMESERVER_DOMAIN="${MATRIX_HOMESERVER_DOMAIN:-${MATRIX_SERVER_NAME}}"
MATRIX_ADMIN_USER="${MATRIX_ADMIN_USER:-admin}"
MATRIX_ADMIN_PASSWORD="${MATRIX_ADMIN_PASSWORD:-change-this}"
MATRIX_INVITE_USERS="${MATRIX_INVITE_USERS:-}"
MATRIX_INVITE_PASSWORD="${MATRIX_INVITE_PASSWORD:-changeme123}"
MATRIX_AGENT_USER="${MATRIX_AGENT_USER:-automata}"
MATRIX_AGENT_PASSWORD="${MATRIX_AGENT_PASSWORD:-${MATRIX_INVITE_PASSWORD}}"
COMPANY_NAME="${COMPANY_NAME:-SentientWave}"
GROUP_NAME="${GROUP_NAME:-Core Team}"
MATRIX_ROOM_NAME="${MATRIX_ROOM_NAME:-${COMPANY_NAME} ${GROUP_NAME} Collaboration}"
MATRIX_ROOM_ALIAS="${MATRIX_ROOM_ALIAS:-}"
MATRIX_MAIN_ROOM_NAME="${MATRIX_MAIN_ROOM_NAME:-${COMPANY_NAME} Main}"
MATRIX_MAIN_ROOM_ALIAS="${MATRIX_MAIN_ROOM_ALIAS:-}"
MATRIX_RANDOM_ROOM_NAME="${MATRIX_RANDOM_ROOM_NAME:-${COMPANY_NAME} Random}"
MATRIX_RANDOM_ROOM_ALIAS="${MATRIX_RANDOM_ROOM_ALIAS:-}"
MATRIX_GOVERNANCE_ROOM_NAME="${MATRIX_GOVERNANCE_ROOM_NAME:-${COMPANY_NAME} Governance}"
MATRIX_GOVERNANCE_ROOM_ALIAS="${MATRIX_GOVERNANCE_ROOM_ALIAS:-governance}"
MATRIX_PROVISION_MARKER="${MATRIX_PROVISION_MARKER:-/data/.matrix_provisioned}"
MATRIX_PROVISION_ALWAYS="${MATRIX_PROVISION_ALWAYS:-false}"

if [ -f "$MATRIX_PROVISION_MARKER" ] && [ "$MATRIX_PROVISION_ALWAYS" != "true" ]; then
  echo "[provision-matrix] Matrix provisioning already completed for this data volume; skipping."
  exit 0
fi

normalize_localpart() {
  local raw="$1"
  raw="${raw#@}"
  raw="${raw%%:*}"
  echo "$raw"
}

normalize_mxid() {
  local raw="$1"
  if [[ "$raw" == @*:* ]]; then
    echo "$raw"
  elif [[ "$raw" == @* ]]; then
    echo "${raw}:${MATRIX_HOMESERVER_DOMAIN}"
  else
    echo "@${raw}:${MATRIX_HOMESERVER_DOMAIN}"
  fi
}

wait_for_matrix() {
  local tries=120
  for _ in $(seq 1 "$tries"); do
    if curl -fsS "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/versions" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  echo "[provision-matrix] Matrix service did not become ready"
  return 1
}

derive_room_alias() {
  local company="$1"
  local group="$2"
  printf '%s-%s-automata' "$company" "$group" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/--+/-/g'
}

slugify() {
  local raw="$1"
  printf '%s' "$raw" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/--+/-/g'
}

fetch_onboarding_alias() {
  local payload
  payload=$(jq -nc \
    --arg company_name "$COMPANY_NAME" \
    --arg group_name "$GROUP_NAME" \
    --arg homeserver_domain "$MATRIX_HOMESERVER_DOMAIN" \
    --arg admin_user "$MATRIX_ADMIN_USER" \
    --arg invitees "$MATRIX_INVITE_USERS" \
    '{company_name:$company_name,group_name:$group_name,homeserver_domain:$homeserver_domain,admin_user:$admin_user,invitees:$invitees}')

  curl -fsS -X POST "http://127.0.0.1:4000/api/v1/onboarding/validate" \
    -H 'content-type: application/json' \
    -d "$payload" 2>/dev/null |
    jq -r '.data.room_alias // empty' || true
}

wait_for_matrix

if [ -z "$MATRIX_ROOM_ALIAS" ]; then
  MATRIX_ROOM_ALIAS="$(fetch_onboarding_alias)"
fi
if [ -z "$MATRIX_ROOM_ALIAS" ]; then
  MATRIX_ROOM_ALIAS="$(derive_room_alias "$COMPANY_NAME" "$GROUP_NAME")"
fi

company_slug="$(slugify "$COMPANY_NAME")"
if [ -z "$MATRIX_MAIN_ROOM_ALIAS" ]; then
  MATRIX_MAIN_ROOM_ALIAS="${MATRIX_ROOM_ALIAS:-${company_slug}-main}"
fi
if [ -z "$MATRIX_RANDOM_ROOM_ALIAS" ]; then
  MATRIX_RANDOM_ROOM_ALIAS="${company_slug}-random"
fi
if [ -z "$MATRIX_GOVERNANCE_ROOM_ALIAS" ]; then
  MATRIX_GOVERNANCE_ROOM_ALIAS="governance"
fi

ADMIN_MXID="$(normalize_mxid "$MATRIX_ADMIN_USER")"
ADMIN_LOCALPART="$(normalize_localpart "$ADMIN_MXID")"
AGENT_MXID="$(normalize_mxid "$MATRIX_AGENT_USER")"
AGENT_LOCALPART="$(normalize_localpart "$AGENT_MXID")"
AGENT_TOKEN_FILE="${MATRIX_AGENT_ACCESS_TOKEN_FILE:-/data/matrix/automata-access-token}"

register_new_matrix_user \
  -u "$ADMIN_LOCALPART" \
  -p "$MATRIX_ADMIN_PASSWORD" \
  -a \
  -c /data/matrix/homeserver.yaml \
  "http://127.0.0.1:${MATRIX_PORT}" >/dev/null 2>&1 || true

register_new_matrix_user \
  -u "$AGENT_LOCALPART" \
  -p "$MATRIX_AGENT_PASSWORD" \
  --no-admin \
  -c /data/matrix/homeserver.yaml \
  "http://127.0.0.1:${MATRIX_PORT}" >/dev/null 2>&1 || true

TOKEN="$( (curl -fsS -X POST "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/v3/login" \
  -H 'content-type: application/json' \
  -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"${ADMIN_LOCALPART}\"},\"password\":\"${MATRIX_ADMIN_PASSWORD}\"}" || echo '{}') | jq -r '.access_token // empty' )"

if [ -z "$TOKEN" ]; then
  echo "[provision-matrix] admin login failed; skipping room provisioning"
  cat <<TXT >/data/connection-info.txt
Provisioning Status: admin_login_failed
Company: $COMPANY_NAME
Group: $GROUP_NAME
Matrix URL: http://localhost:${MATRIX_PORT}
Matrix Admin User: $ADMIN_MXID
Matrix Admin Password: $MATRIX_ADMIN_PASSWORD
Matrix Agent User: $AGENT_MXID
Main Room Alias: #${MATRIX_MAIN_ROOM_ALIAS}:${MATRIX_HOMESERVER_DOMAIN}
Random Room Alias: #${MATRIX_RANDOM_ROOM_ALIAS}:${MATRIX_HOMESERVER_DOMAIN}
Governance Room Alias: #${MATRIX_GOVERNANCE_ROOM_ALIAS}:${MATRIX_HOMESERVER_DOMAIN}
Invite Password: $MATRIX_INVITE_PASSWORD
Automata URL: http://localhost:${PORT:-4000}
Note: Existing Matrix data volume may contain a different password for this user.
TXT
  exit 0
fi

invites_json="$(jq -nc --arg agent "$AGENT_MXID" '[$agent]')"
if [ -n "$MATRIX_INVITE_USERS" ]; then
  while IFS= read -r raw; do
    user="$(echo "$raw" | xargs)"
    [ -z "$user" ] && continue

    mxid="$(normalize_mxid "$user")"
    localpart="$(normalize_localpart "$mxid")"

    register_new_matrix_user \
      -u "$localpart" \
      -p "$MATRIX_INVITE_PASSWORD" \
      -c /data/matrix/homeserver.yaml \
      "http://127.0.0.1:${MATRIX_PORT}" >/dev/null 2>&1 || true

    invites_json="$(echo "$invites_json" | jq --arg u "$mxid" '. + [$u]')"
  done < <(echo "$MATRIX_INVITE_USERS" | tr ',' '\n')
fi

create_room() {
  local room_name="$1"
  local room_alias="$2"
  local room_topic="$3"

  local room_payload
  room_payload="$( (jq -nc \
    --arg name "$room_name" \
    --arg alias "$room_alias" \
    --arg topic "$room_topic" \
    --argjson invite "$invites_json" \
    '{name:$name,room_alias_name:$alias,topic:$topic,preset:"private_chat",invite:$invite}') || echo '{}' )"

  curl -fsS -X POST "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/v3/createRoom" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'content-type: application/json' \
    -d "$room_payload" >/dev/null || true
}

login_user_token() {
  local localpart="$1"
  local password="$2"

  (curl -fsS -X POST "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/v3/login" \
    -H 'content-type: application/json' \
    -d "{\"type\":\"m.login.password\",\"identifier\":{\"type\":\"m.id.user\",\"user\":\"${localpart}\"},\"password\":\"${password}\"}" || echo '{}') \
    | jq -r '.access_token // empty'
}

resolve_room_id() {
  local alias="$1"
  local full_alias="#${alias}:${MATRIX_HOMESERVER_DOMAIN}"
  local encoded
  encoded="$(python3 - <<PY
import urllib.parse
print(urllib.parse.quote("${full_alias}", safe=""))
PY
)"

  (curl -fsS "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/v3/directory/room/${encoded}" \
    -H "Authorization: Bearer $TOKEN" || echo '{}') | jq -r '.room_id // empty'
}

ensure_agent_joined() {
  local room_alias="$1"
  local room_id
  room_id="$(resolve_room_id "$room_alias")"
  [ -z "$room_id" ] && return 0

  curl -fsS -X POST "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/v3/rooms/${room_id}/invite" \
    -H "Authorization: Bearer $TOKEN" \
    -H 'content-type: application/json' \
    -d "{\"user_id\":\"${AGENT_MXID}\"}" >/dev/null 2>&1 || true

  local agent_token
  agent_token="$(login_user_token "$AGENT_LOCALPART" "$MATRIX_AGENT_PASSWORD")"
  [ -z "$agent_token" ] && return 0

  curl -fsS -X POST "http://127.0.0.1:${MATRIX_PORT}/_matrix/client/v3/join/${room_id}" \
    -H "Authorization: Bearer ${agent_token}" \
    -H 'content-type: application/json' \
    -d '{}' >/dev/null 2>&1 || true
}

create_room "$MATRIX_MAIN_ROOM_NAME" "$MATRIX_MAIN_ROOM_ALIAS" "$COMPANY_NAME main collaboration room"
create_room "$MATRIX_RANDOM_ROOM_NAME" "$MATRIX_RANDOM_ROOM_ALIAS" "$COMPANY_NAME random collaboration room"
create_room "$MATRIX_GOVERNANCE_ROOM_NAME" "$MATRIX_GOVERNANCE_ROOM_ALIAS" "$COMPANY_NAME governance room"
MAIN_ROOM_ID="$(resolve_room_id "$MATRIX_MAIN_ROOM_ALIAS")"
RANDOM_ROOM_ID="$(resolve_room_id "$MATRIX_RANDOM_ROOM_ALIAS")"
GOVERNANCE_ROOM_ID="$(resolve_room_id "$MATRIX_GOVERNANCE_ROOM_ALIAS")"
ensure_agent_joined "$MATRIX_MAIN_ROOM_ALIAS"
ensure_agent_joined "$MATRIX_RANDOM_ROOM_ALIAS"
ensure_agent_joined "$MATRIX_GOVERNANCE_ROOM_ALIAS"

AGENT_TOKEN="$(login_user_token "$AGENT_LOCALPART" "$MATRIX_AGENT_PASSWORD")"
if [ -n "$AGENT_TOKEN" ]; then
  mkdir -p "$(dirname "$AGENT_TOKEN_FILE")"
  printf '%s\n' "$AGENT_TOKEN" >"$AGENT_TOKEN_FILE"
  chmod 600 "$AGENT_TOKEN_FILE" || true
fi

cat <<TXT >/data/connection-info.txt
Company: $COMPANY_NAME
Group: $GROUP_NAME
Matrix URL: http://localhost:${MATRIX_PORT}
Matrix Admin User: $ADMIN_MXID
Matrix Admin Password: $MATRIX_ADMIN_PASSWORD
Matrix Agent User: $AGENT_MXID
Main Room Alias: #${MATRIX_MAIN_ROOM_ALIAS}:${MATRIX_HOMESERVER_DOMAIN}
Random Room Alias: #${MATRIX_RANDOM_ROOM_ALIAS}:${MATRIX_HOMESERVER_DOMAIN}
Governance Room Alias: #${MATRIX_GOVERNANCE_ROOM_ALIAS}:${MATRIX_HOMESERVER_DOMAIN}
Main Room ID: ${MAIN_ROOM_ID}
Random Room ID: ${RANDOM_ROOM_ID}
Governance Room ID: ${GOVERNANCE_ROOM_ID}
Invite Password: $MATRIX_INVITE_PASSWORD
Automata URL: http://localhost:${PORT:-4000}
TXT

echo "[provision-matrix] Provisioning complete. See /data/connection-info.txt"
touch "$MATRIX_PROVISION_MARKER" || true
