# All-In-One Container (Automata + Matrix + Temporal + Postgres)

This bundle runs a single container with:
- SentientWave Automata (Phoenix)
- Matrix Synapse homeserver
- Element Web (Matrix web client)
- Temporal local dev server (`temporal server start-dev`)
- PostgreSQL

Podman is the default runtime for local demo readiness.

## Quick Start (Podman-first)

From the repository root:

```bash
deploy/all-in-one/bin/quickstart.sh
```

`quickstart.sh` prompts for onboarding values, writes `deploy/all-in-one/.env`, builds the image, and starts the stack.

## Helper Scripts

Primary helpers:
- `deploy/all-in-one/bin/build.sh`
- `deploy/all-in-one/bin/run.sh`
- `deploy/all-in-one/bin/upgrade.sh`
- `deploy/all-in-one/bin/status.sh`
- `deploy/all-in-one/bin/logs.sh`
- `deploy/all-in-one/bin/stop.sh`
- `deploy/all-in-one/bin/reset.sh --yes`
- `deploy/all-in-one/bin/quickstart.sh`

Optional environment overrides:
- `AIO_ENV_FILE` (default `deploy/all-in-one/.env`)
- `AIO_IMAGE` (default `sentientwave-automata:all-in-one`)
- `AIO_CONTAINER_NAME` (default `sentientwave-all-in-one`)
- `AIO_VOLUME_NAME` (default `sw_all_in_one_data`)
- `AIO_BIND_HOST` (default `0.0.0.0`, binds published ports to all local interfaces)

Security-related env vars (in `deploy/all-in-one/.env`):
- `AUTOMATA_WEB_ADMIN_USER` (default follows Matrix admin user)
- `AUTOMATA_WEB_ADMIN_PASSWORD` (required for admin web login; defaults to Matrix admin password in quickstart)
- `AUTOMATA_QR_BASE_URL` (default external QR endpoint used to render onboarding QR codes)
- `AUTOMATA_SKILLS_PATH` (path to markdown skills directory for agent runtime)
- `AUTOMATA_EMBEDDING_PROVIDER` (embedding backend identifier, for example `local`, `openai`, or custom)
- `AUTOMATA_EMBEDDING_MODEL` (embedding model id used by provider)
- `AUTOMATA_EMBEDDING_API_BASE` (optional API base URL for embedding provider)
- `AUTOMATA_EMBEDDING_API_KEY` (optional API key for embedding provider)
- `AUTOMATA_LLM_PROVIDER` (`local`, `openai`, `gemini`, `openrouter`, `lm-studio`, `ollama`)
- `AUTOMATA_LLM_MODEL` (provider model id, for example `gpt-5.4`, `gemini-3.1-pro-preview`, `openrouter/auto`, `gpt-oss:20b`)
- `AUTOMATA_LLM_API_BASE` (optional provider base URL override)
- `AUTOMATA_LLM_API_KEY` (provider API key when required)
- `AUTOMATA_TEMPORAL_TASK_QUEUE` (Temporal task queue name for agent durable workflows)
- `AUTOMATA_BACKGROUND_WORKERS_ENABLED` (`false` in all-in-one; local execution workers stay out of the Automata boot path)
- `TEMPORAL_BOOT_TIMEOUT_SECONDS` (how long `start-automata.sh` waits for Temporal cluster health before starting Phoenix)
- `PGVECTOR_REQUIRED` (`true` fails startup if pgvector is unavailable; default `false` for current Apple Silicon Podman compatibility)

## Manual Podman Run Commands

```bash
cp deploy/all-in-one/env.template deploy/all-in-one/.env
podman build -f deploy/all-in-one/Dockerfile -t sentientwave-automata:all-in-one .
podman run -d \
  --name sentientwave-all-in-one \
  --env-file deploy/all-in-one/.env \
  -p 0.0.0.0:4000:4000 -p 0.0.0.0:5432:5432 -p 0.0.0.0:8008:8008 -p 0.0.0.0:8081:8081 -p 0.0.0.0:7233:7233 -p 0.0.0.0:8233:8233 \
  -v sw_all_in_one_data:/data \
  sentientwave-automata:all-in-one
```

## Rootless-Compatible Notes

- Rootless Podman is supported and recommended.
- All default exposed ports are above `1024`, so privileged bind is not required.
- If connectivity is blocked on Linux rootless networking, verify `slirp4netns` or `pasta` availability.
- On SELinux hosts, add `:Z` to the volume mount if label-denied access appears.

## Endpoints

- Automata web: `http://localhost:4000`
- PostgreSQL: `localhost:5432`
- Temporal gRPC: `localhost:7233`
- Temporal HTTP/UI endpoint: `http://localhost:8233`
- Matrix Synapse: `http://localhost:8008`
- Element Web: `http://localhost:8081`

Web auth flow:
- Open `http://localhost:4000/login`
- Authenticate with `AUTOMATA_WEB_ADMIN_USER` / `AUTOMATA_WEB_ADMIN_PASSWORD`
- The authenticated console exposes per-user Matrix launch kits (deep links + QR + setup steps)
- Each launch kit includes a user instruction deep link (`/onboarding/user?...`) that can be shared as a QR for fast mobile onboarding.
- Optional: use built-in Element Web at `http://localhost:8081` for browser-based Matrix access.

## Runtime Notes

- The container auto-provisions Matrix admin + invited users from env values.
- It creates two default private Matrix rooms: `main` and `random`.
- It provisions a default agent account: `@automata:<homeserver_domain>`.
- It invites configured users and the `@automata` agent to default rooms.
- Provisioned access details are written to `/data/connection-info.txt`.
- Web console requires admin login at `http://localhost:4000/login`.
- Admin credentials default to `AUTOMATA_WEB_ADMIN_USER` / `AUTOMATA_WEB_ADMIN_PASSWORD`.
- If not explicitly set, those default to Matrix admin credentials from env.
- Most user interaction with Automata is expected in Matrix rooms.
- Agent inference is abstracted via `AUTOMATA_LLM_PROVIDER` and currently supports OpenAI, Google Gemini, OpenRouter, LM Studio, and Ollama.
- Admin UI supports configuring multiple LLM providers and selecting a default at runtime (`/settings/llm`).
- Element Web defaults to `ELEMENT_DEFAULT_HOMESERVER_URL` and is reachable in LAN when `AIO_BIND_HOST=0.0.0.0`.
- Temporal runs in local dev mode for single-container simplicity; production should use dedicated Temporal cluster deployment.
- Automata startup waits for Temporal cluster health before serving traffic, and `deploy/all-in-one/bin/status.sh` reports both Temporal UI and runtime readiness.
- PostgreSQL bootstrap only attempts pgvector extension when `PGVECTOR_REQUIRED=true`.

## Local Verification Commands

```bash
deploy/all-in-one/bin/upgrade.sh
deploy/all-in-one/bin/status.sh

# verify pgvector extension
podman exec sentientwave-all-in-one \
  psql -h 127.0.0.1 -p 5432 -U automata -d sentientwave_dev \
  -c "SELECT extname FROM pg_extension WHERE extname='vector';"

# verify effective runtime env (skills/embedding/task queue)
podman exec sentientwave-all-in-one \
  sh -lc 'env | grep -E "AUTOMATA_SKILLS_PATH|AUTOMATA_EMBEDDING_PROVIDER|AUTOMATA_EMBEDDING_MODEL|AUTOMATA_LLM_PROVIDER|AUTOMATA_LLM_MODEL|AUTOMATA_TEMPORAL_TASK_QUEUE|PGVECTOR_REQUIRED"'

# verify temporal endpoint and queue tooling availability
podman exec sentientwave-all-in-one temporal operator cluster health
```

## Upgrade Without Reinstall

Use this command to rebuild and restart the container while preserving your existing persistent data volume:

```bash
deploy/all-in-one/bin/upgrade.sh
```

If you already built a new image separately:

```bash
deploy/all-in-one/bin/upgrade.sh --skip-build
```

## Matrix-Focused Provisioning

To pre-validate onboarding data from external installers, call:

```bash
curl -X POST http://localhost:4000/api/v1/onboarding/validate \
  -H 'content-type: application/json' \
  -d '{
    "company_name":"Acme",
    "group_name":"Platform",
    "homeserver_domain":"matrix.acme.local",
    "admin_user":"admin",
    "invitees":"alice,bob"
  }'
```
