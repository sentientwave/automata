#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/demo/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<'TXT'
Usage: scripts/demo/prepare-demo.sh [--quiet] [--output-json PATH]

Validates demo services and onboarding payload deterministically.
Environment variables can override demo defaults (DEMO_*).
TXT
}

OUTPUT_JSON=""
QUIET="false"

while (($# > 0)); do
  case "$1" in
    --output-json)
      OUTPUT_JSON="${2:-}"
      shift 2
      ;;
    --quiet)
      QUIET="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[demo] unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd curl
require_cmd jq
load_demo_defaults

ROOT_DIR="$(demo_root_dir)"
QUICKSTART_SCRIPT="${ROOT_DIR}/deploy/all-in-one/bin/quickstart.sh"
DEMO_BOOTSTRAP="${DEMO_BOOTSTRAP:-true}"

if ! curl -fsS "${DEMO_AUTOMATA_URL}/" >/dev/null 2>&1; then
  if [[ "${DEMO_BOOTSTRAP}" == "true" ]] && [[ -x "${QUICKSTART_SCRIPT}" ]]; then
    echo "[demo] Stack not running. Launching Podman quickstart..."
    "${QUICKSTART_SCRIPT}"
  else
    echo "[demo] Automata not reachable at ${DEMO_AUTOMATA_URL}. Start the stack first." >&2
    exit 1
  fi
fi

admin_mxid="$(normalize_mxid "$DEMO_MATRIX_ADMIN_USER" "$DEMO_MATRIX_HOMESERVER_DOMAIN")"
invites_csv="$(build_invites_csv "$DEMO_USERS" "$DEMO_MATRIX_HOMESERVER_DOMAIN")"
payload="$(build_onboarding_payload \
  "$DEMO_COMPANY_KEY" \
  "$DEMO_COMPANY_NAME" \
  "$admin_mxid" \
  "$DEMO_MATRIX_HOMESERVER_DOMAIN" \
  "$DEMO_GROUP_KEY" \
  "$DEMO_GROUP_NAME" \
  "$DEMO_GROUP_VISIBILITY" \
  "$DEMO_GROUP_AUTO_JOIN" \
  "$invites_csv")"

wait_for_http "automata" "${DEMO_AUTOMATA_URL}/" "$DEMO_WAIT_SECONDS"
wait_for_http "matrix" "${DEMO_MATRIX_URL}/_matrix/client/versions" "$DEMO_WAIT_SECONDS"
wait_for_http "temporal-ui" "${DEMO_TEMPORAL_UI_URL}/" "$DEMO_WAIT_SECONDS"

onboarding_response="$(post_onboarding_validate "$DEMO_AUTOMATA_URL" "$payload")"

if ! echo "$onboarding_response" | jq -e '.data.company.key and .data.group.key and (.data.invites | type == "array")' >/dev/null; then
  echo "[demo] onboarding validation response missing expected fields" >&2
  echo "$onboarding_response" | jq . >&2 || true
  exit 1
fi

company_name="$(echo "$onboarding_response" | jq -r '.data.company.name')"
group_name="$(echo "$onboarding_response" | jq -r '.data.group.name')"
room_alias_localpart="$(derive_room_alias_localpart "$company_name" "$group_name")"
room_alias_full="#${room_alias_localpart}:${DEMO_MATRIX_HOMESERVER_DOMAIN}"

context_json="$(jq -n \
  --arg automata_url "$DEMO_AUTOMATA_URL" \
  --arg matrix_url "$DEMO_MATRIX_URL" \
  --arg temporal_ui_url "$DEMO_TEMPORAL_UI_URL" \
  --arg company_key "$(echo "$onboarding_response" | jq -r '.data.company.key')" \
  --arg company_name "$company_name" \
  --arg group_key "$(echo "$onboarding_response" | jq -r '.data.group.key')" \
  --arg group_name "$group_name" \
  --arg homeserver_domain "$DEMO_MATRIX_HOMESERVER_DOMAIN" \
  --arg admin_user "$admin_mxid" \
  --arg admin_password "$DEMO_MATRIX_ADMIN_PASSWORD" \
  --arg invite_users "$invites_csv" \
  --arg invite_password "$DEMO_INVITE_PASSWORD" \
  --arg room_alias_localpart "$room_alias_localpart" \
  --arg room_alias_full "$room_alias_full" \
  --argjson invites "$(echo "$onboarding_response" | jq '.data.invites')" \
  --argjson onboarding "$(echo "$onboarding_response" | jq '.data')" \
  '{
    services: {
      automata_url: $automata_url,
      matrix_url: $matrix_url,
      temporal_ui_url: $temporal_ui_url
    },
    onboarding: {
      company_key: $company_key,
      company_name: $company_name,
      group_key: $group_key,
      group_name: $group_name,
      homeserver_domain: $homeserver_domain,
      admin_user: $admin_user,
      invites: $invites,
      raw: $onboarding
    },
    matrix: {
      admin_user: $admin_user,
      admin_password: $admin_password,
      invite_users: $invite_users,
      invite_password: $invite_password,
      room_alias_localpart: $room_alias_localpart,
      room_alias: $room_alias_full
    }
  }')"

if [[ -n "$OUTPUT_JSON" ]]; then
  mkdir -p "$(dirname "$OUTPUT_JSON")"
  printf '%s\n' "$context_json" > "$OUTPUT_JSON"
fi

if [[ "$QUIET" != "true" ]]; then
  cat <<TXT
Demo prep complete.

Service validation:
- Automata: OK (${DEMO_AUTOMATA_URL}/)
- Matrix: OK (${DEMO_MATRIX_URL}/_matrix/client/versions)
- Temporal UI: OK (${DEMO_TEMPORAL_UI_URL}/)

Onboarding validation:
- Endpoint: POST ${DEMO_AUTOMATA_URL}/api/v1/onboarding/validate
- Company/Group: ${company_name} / ${group_name}
- Invites: ${invites_csv}

Matrix login details:
- Admin user: ${admin_mxid}
- Admin password: ${DEMO_MATRIX_ADMIN_PASSWORD}
- Invite password: ${DEMO_INVITE_PASSWORD}
- Room alias: ${room_alias_full}

Run walkthrough checklist:
  scripts/demo/walkthrough-demo.sh
TXT
fi
