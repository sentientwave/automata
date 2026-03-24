# Operations and Deployment

## Runtime Targets
- Docker: default local dev and CI
- Podman: rootless Linux deployments with systemd/Quadlet
- Apple Containers: local Apple Silicon development path
- LXC: unprivileged containers only
- NixOS VMs: canonical production substrate

## Topology
Community:
- single region, simple HA profile

Enterprise:
- multi-AZ service pools
- stronger tenancy isolation
- stricter backup and recovery SLOs

## Temporal Constraints
- maintain visibility store
- keep payload/history limits in check
- upgrade sequentially by minor version

## Backups
- PostgreSQL WAL + PITR
- Temporal persistence and visibility backups together
- quarterly restore drills

## All-In-One (Dev/Pilot, Single Container)

The `deploy/all-in-one` bundle runs:
- SentientWave Automata (Phoenix app)
- PostgreSQL 15
- Matrix Synapse homeserver
- Temporal-compatible local durable engine (`temporal server start-dev` with sqlite persistence)

This mode is for local development, demos, and pilot environments where a single-node stack is acceptable.

### Files
- `deploy/all-in-one/Dockerfile`
- `deploy/all-in-one/supervisord.conf`
- `deploy/all-in-one/bin/common.sh`
- `deploy/all-in-one/bin/quickstart.sh`
- `deploy/all-in-one/bin/build.sh`
- `deploy/all-in-one/bin/run.sh`
- `deploy/all-in-one/bin/upgrade.sh`
- `deploy/all-in-one/bin/status.sh`
- `deploy/all-in-one/bin/logs.sh`
- `deploy/all-in-one/bin/stop.sh`
- `deploy/all-in-one/bin/reset.sh`
- `deploy/all-in-one/scripts/entrypoint.sh`
- `deploy/all-in-one/scripts/bootstrap-postgres.sh`
- `deploy/all-in-one/scripts/bootstrap-matrix.sh`
- `deploy/all-in-one/scripts/start-postgres.sh`
- `deploy/all-in-one/scripts/start-temporal.sh`
- `deploy/all-in-one/scripts/start-matrix.sh`
- `deploy/all-in-one/scripts/start-automata.sh`
- `deploy/all-in-one/env.template`

### Quick Start
1. Prompted setup + build + run:
   `deploy/all-in-one/bin/quickstart.sh`
2. Manual helper flow:
   `deploy/all-in-one/bin/build.sh`
   `deploy/all-in-one/bin/run.sh`

### Manual Podman Run
```bash
cp deploy/all-in-one/env.template deploy/all-in-one/.env
podman build -f deploy/all-in-one/Dockerfile -t sentientwave-automata:all-in-one .
podman run -d \
  --name sentientwave-all-in-one \
  --env-file deploy/all-in-one/.env \
  -p 4000:4000 -p 5432:5432 -p 7233:7233 -p 8233:8233 -p 8008:8008 \
  -v sw_all_in_one_data:/data \
  sentientwave-automata:all-in-one
```

### Rootless Podman Notes
- Rootless mode is supported and preferred for local demos.
- Default published ports are above `1024`, so privileged bind is not needed.
- On SELinux hosts, add `:Z` on the data mount when label-denied volume access appears.
- If localhost forwarding fails on Linux rootless setup, verify rootless networking (`slirp4netns` or `pasta`) is installed and available.

### Endpoints
- Automata web: `http://localhost:4000`
- PostgreSQL: `localhost:5432`
- Temporal gRPC: `localhost:7233`
- Temporal HTTP/UI endpoint: `http://localhost:8233`
- Matrix Synapse: `http://localhost:8008`

### Runtime Notes
- Services are managed by `supervisord` inside the container.
- Postgres and Matrix bootstrap are idempotent and run at container startup.
- Postgres bootstrap enables `pgvector` extension (`CREATE EXTENSION IF NOT EXISTS vector`).
- Matrix provisioning auto-creates admin user, invite users, and a collaboration room.
- Matrix provisioning auto-creates admin user, default `@automata` agent user, and default rooms `main` + `random`.
- Set `COMPANY_NAME`, `GROUP_NAME`, `MATRIX_ADMIN_USER`, `MATRIX_ADMIN_PASSWORD`, and `MATRIX_INVITE_USERS` in `.env`.
- Set `AUTOMATA_WEB_ADMIN_USER` and `AUTOMATA_WEB_ADMIN_PASSWORD` to require authenticated web-console access.
- Set `AUTOMATA_SKILLS_PATH`, `AUTOMATA_EMBEDDING_PROVIDER`, `AUTOMATA_EMBEDDING_MODEL`, `AUTOMATA_EMBEDDING_API_BASE`, `AUTOMATA_EMBEDDING_API_KEY`, `AUTOMATA_LLM_PROVIDER`, `AUTOMATA_LLM_MODEL`, `AUTOMATA_LLM_API_BASE`, `AUTOMATA_LLM_API_KEY`, and `AUTOMATA_TEMPORAL_TASK_QUEUE` for agent runtime configuration.
- `PGVECTOR_REQUIRED=true` enforces hard failure if pgvector is unavailable.
- Default is `PGVECTOR_REQUIRED=false` for Apple Silicon Podman compatibility due an upstream `CREATE EXTENSION vector` crash observed on PostgreSQL ARM builds in this stack.
- Automata waits for Postgres, runs `mix ecto.create` + `mix ecto.migrate`, then starts Phoenix.
- Data is persisted under `/data` (mount this as a Podman volume).
- Generated connection summary is written to `/data/connection-info.txt`.

### Health and Logs
- Tail logs:
  `deploy/all-in-one/bin/logs.sh`
- Check overall status:
  `deploy/all-in-one/bin/status.sh`
- Upgrade in place (preserves `/data` volume and `.env`):
  `deploy/all-in-one/bin/upgrade.sh`
- Check running processes:
  `podman exec sentientwave-all-in-one supervisorctl status`
- Check app health:
  `curl -fsS http://localhost:4000/`

### Admin Console Access
- Login endpoint: `http://localhost:4000/login`
- Use `AUTOMATA_WEB_ADMIN_USER` + `AUTOMATA_WEB_ADMIN_PASSWORD`
- Authenticated console includes per-user Matrix deep links, QR codes, and setup instructions for fast onboarding.
- User instruction deep links are available at `/onboarding/user` with generated query parameters.

### Internal Directory + Matrix Reconciliation
- Automata now keeps an internal directory for people/agent identities and continuously reconciles it to Matrix.
- Reconciliation worker interval: `MATRIX_RECONCILE_INTERVAL_MS` (default `60000`).
- Optional agent seed users: `AUTOMATA_AGENT_USERS` (comma-separated) and `AUTOMATA_AGENT_PASSWORD`.
- Authenticated admin API:
  - `GET /api/v1/directory/users`
  - `POST /api/v1/directory/users`
  - `POST /api/v1/directory/reconcile`

### Durable Agent Runtime APIs
- Mention ingress (starts one durable run per mentioned agent):
  - `POST /api/v1/mentions`
- Authenticated admin APIs:
  - `GET /api/v1/agent-runs`
  - `GET /api/v1/agent-runs/:id`
  - `POST /api/v1/agent-memories`
  - `GET /api/v1/agent-memories/search`

Example mention payload:
`{"room_id":"!ops:localhost","sender_mxid":"@admin:localhost","message_id":"$evt42","body":"@automata summarize and propose next steps"}`

### Matrix Mention Ingestion (All-in-one)
- `MATRIX_ADAPTER=synapse` enables direct Matrix client API integration.
- `MATRIX_POLL_ENABLED=true` enables Automata poller over `/_matrix/client/v3/sync`.
- Poll interval and long-poll timeout:
  - `MATRIX_SYNC_INTERVAL_MS` (default `2000`)
  - `MATRIX_SYNC_TIMEOUT_MS` (default `25000`)
- The poller ignores the bot's own events and forwards room `m.room.message` events into mention dispatch.
- Mention-triggered agent inference runs through an abstracted provider layer and supports:
  - `openai`
  - `gemini`
  - `openrouter`
  - `lm-studio`
  - `ollama`
  - `local` fallback

### Migration-Free Rollout Guidance
- No database schema change is required for admin auth or launch-kit features.
- Existing `.env` files remain valid; add `AUTOMATA_WEB_ADMIN_USER` and `AUTOMATA_WEB_ADMIN_PASSWORD` to enforce web login.
- Existing `/data` volume remains valid; provisioning artifacts are generated dynamically at request time.
- Roll out with in-place restart:
  `deploy/all-in-one/bin/upgrade.sh`

### Local Verification Commands
- Upgrade and restart:
  `deploy/all-in-one/bin/upgrade.sh`
- Validate services:
  `deploy/all-in-one/bin/status.sh`
- Validate pgvector extension:
  `podman exec sentientwave-all-in-one psql -h 127.0.0.1 -p 5432 -U automata -d sentientwave_dev -c "SELECT extname FROM pg_extension WHERE extname='vector';"`
- Validate runtime env wiring:
  `podman exec sentientwave-all-in-one sh -lc 'env | grep -E "AUTOMATA_SKILLS_PATH|AUTOMATA_EMBEDDING_PROVIDER|AUTOMATA_EMBEDDING_MODEL|AUTOMATA_LLM_PROVIDER|AUTOMATA_LLM_MODEL|AUTOMATA_TEMPORAL_TASK_QUEUE|PGVECTOR_REQUIRED"'`

### Stop / Reset
- Stop and remove container:
  `deploy/all-in-one/bin/stop.sh`
- Reset including persistent data (destructive):
  `deploy/all-in-one/bin/reset.sh --yes`
