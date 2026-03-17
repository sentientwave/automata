# Demo Prep and Walkthrough

This demo automation is shell-based and deterministic. It validates required services, posts onboarding payloads with company/group/users, and prints a walkthrough checklist that includes Matrix login details and room alias.

## Scripts

- `scripts/demo/prepare-demo.sh`
  - If stack is down and `DEMO_BOOTSTRAP=true`, it runs `deploy/all-in-one/bin/quickstart.sh`.
  - Validates service reachability for Automata, Matrix, and Temporal UI.
  - Posts `POST /api/v1/onboarding/validate` using `company`, `group`, and `invites` derived from `DEMO_USERS`.
  - Prints normalized demo details (including Matrix credentials and room alias).
  - Optional `--output-json` writes a machine-readable context file.
- `scripts/demo/walkthrough-demo.sh`
  - Runs prep in quiet mode and prints a clear presenter checklist.

## Requirements

- `curl`
- `jq`
- Running stack endpoints (defaults):
  - `http://localhost:4000` (Automata)
  - `http://localhost:8008` (Matrix)
  - `http://localhost:8233` (Temporal UI)

## Usage

From repo root:

```bash
scripts/demo/prepare-demo.sh
```

Generate deterministic JSON context for other automation steps:

```bash
scripts/demo/prepare-demo.sh --output-json /tmp/sentientwave-demo-context.json
```

Print presenter-ready walkthrough checklist:

```bash
scripts/demo/walkthrough-demo.sh
```

## Environment Overrides

- `DEMO_AUTOMATA_URL` (default `http://localhost:4000`)
- `DEMO_MATRIX_URL` (default `http://localhost:8008`)
- `DEMO_TEMPORAL_UI_URL` (default `http://localhost:8233`)
- `DEMO_WAIT_SECONDS` (default `45`)
- `DEMO_COMPANY_KEY` (default `sentientwave`)
- `DEMO_COMPANY_NAME` (default `SentientWave`)
- `DEMO_GROUP_KEY` (default `core-team`)
- `DEMO_GROUP_NAME` (default `Core Team`)
- `DEMO_MATRIX_HOMESERVER_DOMAIN` (default `${MATRIX_HOMESERVER_DOMAIN:-localhost}`)
- `DEMO_MATRIX_ADMIN_USER` (default `${MATRIX_ADMIN_USER:-admin}`)
- `DEMO_MATRIX_ADMIN_PASSWORD` (default `${MATRIX_ADMIN_PASSWORD:-change-this}`)
- `DEMO_USERS` (default `${MATRIX_INVITE_USERS:-alice,bob}`)
- `DEMO_INVITE_PASSWORD` (default `${MATRIX_INVITE_PASSWORD:-changeme123}`)
- `DEMO_GROUP_VISIBILITY` (default `private`)
- `DEMO_GROUP_AUTO_JOIN` (default `true`)
- `DEMO_BOOTSTRAP` (default `true`)

Example override:

```bash
DEMO_COMPANY_NAME="Acme Corp" \
DEMO_GROUP_NAME="Platform Team" \
DEMO_USERS="alice,bob,@carol:matrix.acme.local" \
DEMO_MATRIX_HOMESERVER_DOMAIN="matrix.acme.local" \
scripts/demo/walkthrough-demo.sh
```
