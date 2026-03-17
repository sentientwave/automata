# SentientWave Automata

SentientWave Automata is a Matrix-native collaboration runtime where people and AI agents coordinate in shared rooms with durable workflow execution.

Automata is designed for team operations where chat is the primary interface and workflows must stay reliable across failures, retries, and long-running tasks.

## What It Is

- Matrix-first multi-agent collaboration platform
- Elixir/Phoenix control plane and API
- Temporal-backed durable execution
- PostgreSQL persistence
- Community Edition (source-available) and Enterprise Edition

## Why Teams Use It

- Keep humans and agents in the same Matrix rooms
- Run durable agent workflows that survive restarts and transient failures
- Maintain internal people/agent directory and reconcile with Matrix accounts
- Attach pluggable LLM providers and tools without rewriting core flows
- Deploy locally with Podman using an all-in-one container path

## Community vs Enterprise

Community Edition includes:
- Matrix room collaboration (people + agents)
- Basic orchestration APIs and local runtime
- Internal directory to Matrix user reconciliation
- Podman-first all-in-one deployment for local/self-hosted usage

Enterprise Edition (commercial license) includes:
- SSO and advanced identity controls
- Policy and compliance features
- Enterprise support and hardening options

## Architecture At A Glance

- `Matrix` is the collaboration and messaging surface
- `Automata (Phoenix)` provides admin UI, orchestration APIs, directory, and tool/LLM configuration
- `Temporal` runs durable workflows and activities for agent execution
- `PostgreSQL` stores Automata state, workflow metadata, and memory records

## Quick Start (Local Dev)

```bash
mix deps.get
mix phx.server
```

Open [http://localhost:4000](http://localhost:4000).

## Podman All-In-One (Recommended Demo Path)

```bash
deploy/all-in-one/bin/quickstart.sh
```

This bootstrap path provisions Matrix + Temporal + PostgreSQL + Automata with integrated configuration for local evaluation.

Useful commands:

```bash
deploy/all-in-one/bin/status.sh
deploy/all-in-one/bin/upgrade.sh
deploy/all-in-one/bin/logs.sh
```

## First-Day Demo Flow

1. Start all-in-one with `deploy/all-in-one/bin/quickstart.sh`
2. Open Automata web UI at `http://localhost:4000`
3. Configure at least one LLM provider in the admin UI
4. Open Matrix client (Element/Element Web) and join `main` room
5. Send a message mentioning `@automata` in room chat
6. Verify agent typing indicator and response in room
7. Validate workflow execution in Automata API (`/api/v1/agent-runs`)

## Admin APIs (Authenticated)

Login first (session cookie):

```bash
curl -c cookie.txt -b cookie.txt -X POST http://localhost:4000/login \
  -d "username=admin&password=<your-admin-password>"
```

Directory + reconciliation APIs:

```bash
curl -b cookie.txt http://localhost:4000/api/v1/directory/users
curl -b cookie.txt -X POST http://localhost:4000/api/v1/directory/users \
  -H 'content-type: application/json' \
  -d '{"localpart":"alice","kind":"person"}'
curl -b cookie.txt -X POST http://localhost:4000/api/v1/directory/reconcile
```

Agent runtime APIs:

```bash
# Mention-triggered durable runs
curl -X POST http://localhost:4000/api/v1/mentions \
  -H 'content-type: application/json' \
  -d '{"room_id":"!demo:localhost","sender_mxid":"@admin:localhost","message_id":"$evt1","body":"@automata summarize this thread"}'

# List durable agent runs (admin auth required)
curl -b cookie.txt http://localhost:4000/api/v1/agent-runs

# Ingest/query per-agent RAG memory (admin auth required)
curl -b cookie.txt -X POST http://localhost:4000/api/v1/agent-memories \
  -H 'content-type: application/json' \
  -d '{"agent_id":"<agent-id>","content":"Incident report timeline","source":"matrix:!demo:localhost"}'
curl -b cookie.txt "http://localhost:4000/api/v1/agent-memories/search?agent_id=<agent-id>&query=incident&top_k=5"
```

## Repository Layout

- `apps/sentientwave_automata`: core domain runtime
- `apps/sentientwave_automata_web`: web UI and HTTP API
- `deploy/all-in-one`: single-container deployment tooling
- `docs`: architecture, operations, and product docs
- `scripts`: helper scripts for local operations and demo workflows

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Operations](docs/OPERATIONS.md)
- [Product](docs/PRODUCT.md)
- [Demo Guide](docs/DEMO.md)
- [QA Strategy](docs/QA_STRATEGY.md)
- [Release Process](RELEASE.md)
- [Support](SUPPORT.md)
- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Roadmap](ROADMAP.md)
- [Progress](PROGRESS.md)
- [Changelog](CHANGELOG.md)
- [Code Owners](CODEOWNERS)

## Version

Current version is tracked in [VERSION](VERSION).

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md), [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md), and [SECURITY.md](SECURITY.md) before opening issues or pull requests.

## Support

Support channels and response expectations are documented in [SUPPORT.md](SUPPORT.md).

## License

This repository is distributed under the SentientWave Community Source License.

Important: this license is source-available and includes commercial restrictions (for example, no third-party cloud/hosting offerings without a separate SentientWave license).

See [LICENSE](LICENSE) for full terms.
