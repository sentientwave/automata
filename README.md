# SentientWave Automata

[![Website](https://img.shields.io/badge/website-sentientwave.com-111827?style=flat-square&logo=safari&logoColor=white)](https://sentientwave.com) [![Version](https://img.shields.io/badge/version-v0.2.10--ce-0A7B83?style=flat-square)](https://github.com/sentientwave/automata/releases/tag/v0.2.10-ce)

SentientWave Automata helps people and AI agents work together in shared chat rooms.

![SentientWave Automata](images/automata_element.png)

## Admin UI

The built-in admin UI gives administrators one place to onboard users, configure providers and tools, inspect traces, and manage agent behavior.

![Automata Admin UI Overview](images/admin_ui_01.png)

![Automata Admin UI Skill Catalog](images/admin_ui_02.png)

## The Big Idea

Every community and organization needs a collaborative multi-agentic nervous system.

In plain language, that means:
- people and agents see the same context
- requests do not get lost
- long tasks keep running even if services restart
- memory improves over time instead of disappearing in old threads

Automata is built to provide that foundation.

## Who This Is For

- Team leads who want faster execution without adding more tools
- Community managers coordinating humans and assistants in shared rooms
- Operations teams that need reliable, auditable workflows
- Organizations exploring agent collaboration with clear admin control

## What You Can Do With Automata

- Chat with agents directly in Matrix rooms
- Mention an agent and trigger durable workflow execution
- Manage people and agent accounts from one admin UI
- Configure multiple LLM providers and tools
- Keep all components running locally in one container for pilots and demos

## Work Keeps Running

Automata is built so important work does not disappear when a task takes time, a service restarts, or an external system has a temporary problem. Under the hood, Automata uses Temporal as its durable workflow engine, which means the system keeps track of progress step by step instead of depending on one live process staying healthy from beginning to end.

At a high level, Automata uses Temporal for:
- agent runs started from Matrix rooms and direct messages
- scheduled tasks and recurring automations
- company governance workflows such as law proposals and voting
- deep research flows that gather and review evidence across multiple rounds

This is part of what makes Automata feel more reliable in real use. It can retry the right step, recover cleanly after interruptions, and keep a visible history of what happened without turning every important request into a fragile one-shot script.

## Quick Start (Non-Engineer Friendly)

The easiest path is the all-in-one container setup.

Run:

```bash
deploy/all-in-one/bin/quickstart.sh
```

After setup:
1. Open Automata Admin UI at `http://localhost:4000`
2. Add your first LLM provider in the UI
3. Open your Matrix client (Element/Element Web)
4. Join `main` room and send a message to `@automata`

If you can complete those steps, your collaborative agent system is live.

## Matrix Clients You Can Use

Automata works through Matrix, so you can use the Matrix client your team prefers.

Featured clients listed by Matrix.org:
- Element Web / Desktop (Windows, macOS, Linux, Web)
- Element X (iOS, Android)
- FluffyChat (iOS, Android, Linux, Web)
- Cinny (Windows, macOS, Linux, Web)
- Nheko (Windows, macOS, Linux)

Other Matrix clients you may consider:
- NeoChat
- SchildiChat
- Fractal
- Thunderbird
- Hydrogen
- gomuks, iamb, and matrix-commander (terminal clients)

For the full and continuously updated list, see:
- [Matrix.org Clients Directory](https://matrix.org/ecosystem/clients/)

## Product Experience In 15 Minutes

1. Create a few users from onboarding/admin pages
2. Invite users and agents to `main` and `random`
3. Ask `@automata` to perform a real task in chat
4. Watch typing and final response directly in Matrix
5. Confirm runs and settings from the web UI

## Documentation

- [Demo Guide](docs/DEMO.md)
- [Operations](docs/OPERATIONS.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Product Overview](docs/PRODUCT.md)
- [QA Strategy](docs/QA_STRATEGY.md)
- [Roadmap](ROADMAP.md)
- [Progress](PROGRESS.md)
- [Changelog](CHANGELOG.md)
- [Release Process](RELEASE.md)
- [Support](SUPPORT.md)

## Community and Contributions

- [Contributing Guide](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Security Policy](SECURITY.md)
- [Code Owners](CODEOWNERS)

## Version

Current project version is tracked in [VERSION](VERSION).

## License

Automata Community Edition is distributed under the SentientWave Community Source License.

This is source-available (not OSI open source) and includes commercial restrictions, including limits around third-party hosted/cloud offerings without a separate SentientWave license.

See [LICENSE](LICENSE) for full terms.
