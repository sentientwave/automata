#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREP_SCRIPT="${SCRIPT_DIR}/prepare-demo.sh"

if [[ ! -x "$PREP_SCRIPT" ]]; then
  echo "[demo] missing executable prep script: $PREP_SCRIPT" >&2
  exit 1
fi

tmp_file="$(mktemp -t sentientwave-demo-context.XXXXXX.json)"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

"$PREP_SCRIPT" --quiet --output-json "$tmp_file"

company_name="$(jq -r '.onboarding.company_name' "$tmp_file")"
group_name="$(jq -r '.onboarding.group_name' "$tmp_file")"
room_alias="$(jq -r '.matrix.room_alias' "$tmp_file")"
admin_user="$(jq -r '.matrix.admin_user' "$tmp_file")"
admin_password="$(jq -r '.matrix.admin_password' "$tmp_file")"
invite_password="$(jq -r '.matrix.invite_password' "$tmp_file")"
invite_users="$(jq -r '.matrix.invite_users' "$tmp_file")"
automata_url="$(jq -r '.services.automata_url' "$tmp_file")"
matrix_url="$(jq -r '.services.matrix_url' "$tmp_file")"
temporal_ui_url="$(jq -r '.services.temporal_ui_url' "$tmp_file")"

cat <<'TXT' | sed \
  -e "s|__COMPANY_NAME__|${company_name}|g" \
  -e "s|__GROUP_NAME__|${group_name}|g" \
  -e "s|__ROOM_ALIAS__|${room_alias}|g" \
  -e "s|__ADMIN_USER__|${admin_user}|g" \
  -e "s|__ADMIN_PASSWORD__|${admin_password}|g" \
  -e "s|__INVITE_USERS__|${invite_users}|g" \
  -e "s|__INVITE_PASSWORD__|${invite_password}|g" \
  -e "s|__AUTOMATA_URL__|${automata_url}|g" \
  -e "s|__MATRIX_URL__|${matrix_url}|g" \
  -e "s|__TEMPORAL_UI_URL__|${temporal_ui_url}|g"
SentientWave Automata demo checklist

Scope:
- Company: __COMPANY_NAME__
- Group: __GROUP_NAME__
- Matrix room alias: __ROOM_ALIAS__

Login details:
- Matrix admin: __ADMIN_USER__
- Matrix admin password: __ADMIN_PASSWORD__
- Invited users: __INVITE_USERS__
- Invite user password: __INVITE_PASSWORD__

Service links:
- Automata: __AUTOMATA_URL__
- Matrix homeserver: __MATRIX_URL__
- Temporal UI: __TEMPORAL_UI_URL__

Walkthrough:
1. Validate stack status with `curl -fsS __AUTOMATA_URL__/`, `curl -fsS __MATRIX_URL__/_matrix/client/versions`, and `curl -fsS __TEMPORAL_UI_URL__/`.
2. Open Matrix client (Element), login as `__ADMIN_USER__`, and confirm the room `__ROOM_ALIAS__` is visible.
3. Confirm invited users can login with password `__INVITE_PASSWORD__` and join the demo room.
4. Call `POST __AUTOMATA_URL__/api/v1/onboarding/validate` with company/group/users payload and show normalized output.
5. Trigger a workflow from Automata API/UI and show Temporal UI activity.
6. Send a room message to demonstrate Matrix-first collaboration context.
TXT
