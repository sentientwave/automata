# SentientWave Automata

[![Website](https://img.shields.io/badge/website-sentientwave.com-111827?style=flat-square&logo=safari&logoColor=white)](https://sentientwave.com) [![Version](https://img.shields.io/badge/version-v0.2.10--ce-0A7B83?style=flat-square)](https://github.com/sentientwave/automata/releases/tag/v0.2.10-ce)

Automata is a Matrix-native workspace and admin dashboard for teams that want people and AI assistants to handle real work together. Conversations happen in chat. Setup, control, and visibility happen in the web dashboard. Long-running work keeps going until it finishes.

Instead of scattering prompts across separate tools, Automata gives an organization one place to coordinate assistants, tools, identities, activity logs, and task history. It is a new operational layer for a world where humans are no longer the only actors carrying work forward and making decisions.

![SentientWave Automata](images/automata_element.png)

## What Automata Is

Automata turns team chat into a shared operating environment for AI-assisted work. People can ask for help in Matrix rooms or direct messages, assistants can continue multi-step tasks, and administrators can decide which AI services, tools, skills, and rules are allowed in the system.

It is also designed for higher autonomy over time. Teams can adjust how the system behaves through skills, schedules, permissions, and a dynamic governance layer built around laws and proposals, so the organization can evolve how assistants operate without losing oversight.

Automata is not just a chatbot window. It combines:
- Matrix chat for day-to-day collaboration
- a web admin dashboard for setup and control
- durable workflows so important tasks do not disappear halfway through
- activity logs and task history so teams can see what happened

## Why It Exists

Most teams are trying to use AI inside tools that were built for short conversations, not real operational work. That creates common problems:
- context gets lost in old threads
- tasks stop when a browser tab, process, or service goes away
- nobody has one place to control users, assistants, tools, and rules
- it is hard to review what happened after the fact

Automata exists to make AI-assisted work dependable, visible, and governable.

## What You Can Do With It

- work with assistants in shared Matrix rooms and private messages
- run tasks that keep moving even when the system restarts
- connect AI model services and choose which tools assistants can use
- onboard people, agents, and service accounts, then keep Matrix identities in sync
- review provider activity, traces, and task history from one place
- control which tools, skills, schedules, and permissions assistants receive
- evolve system behavior through laws, proposals, and governance workflows

## How You Use It

Automata has two everyday surfaces:
- Admin dashboard: onboard users, connect providers, manage tools and permissions, review activity logs and task history, and control assistant behavior
- Matrix chat: ask assistants for work, collaborate in rooms, send direct messages, and receive results where the conversation already lives

## Fastest Way to Try It

If you have Podman and OpenSSL installed, the easiest local path is the all-in-one container setup. It prompts for the basics, writes an environment file, and starts Automata, Matrix, PostgreSQL, and Temporal on one machine.

```bash
deploy/all-in-one/bin/quickstart.sh
```

After startup:
1. Open `http://localhost:4000` or `http://localhost:4000/login` if you enabled admin authentication.
2. Sign in to the admin dashboard and confirm your initial provider settings.
3. Open a Matrix client such as Element and sign in with the generated credentials from `deploy/all-in-one/.env` or the scripted walkthrough in the Demo Guide.
4. Join the `main` room and send a message to `@automata`.
5. Return to the admin dashboard to review the reply, logs, and task history.

If you can complete those steps, your system is up and ready to use.

For a scripted walkthrough, see [Demo Guide](docs/DEMO.md).

## Why Work Keeps Running

Automata is built so important work does not disappear when a task takes time or the system restarts. Under the hood, it uses Temporal, a workflow system that saves progress step by step instead of depending on one live process staying healthy from beginning to end.

At a high level, Automata uses Temporal for:
- tasks started from Matrix rooms and direct messages
- scheduled tasks and recurring automations
- company governance workflows such as law proposals and voting
- multi-step research tasks that gather and review evidence across rounds

This is part of what makes Automata feel more reliable in real use. It can retry the right step, recover after interruptions, and keep a clear record of what happened.

## High Autonomy and Self-Evolution

Automata is built for systems that need to become more capable without becoming chaotic. Instead of hiding behavior changes in scattered prompts or one-off scripts, it gives teams explicit ways to evolve the system over time.

That includes:
- changing assistant behavior through skills, tools, schedules, and permissions
- defining company laws that apply across agent reasoning
- proposing, reviewing, and voting on governance changes inside Matrix
- keeping a visible history of how the system was changed and why

This makes higher autonomy more practical. Automata can adapt as the organization learns, while keeping those changes reviewable, governable, and tied to clear rules.

## Admin Dashboard

The built-in admin dashboard gives administrators one place to onboard users, connect providers, control tools and permissions, review activity logs, and manage assistant behavior. It also includes onboarding helpers, directory pages, traces, skills, and scheduling controls for day-to-day operations.

![Automata Admin UI Overview](images/admin_ui_01.png)

![Automata Admin UI Skill Catalog](images/admin_ui_02.png)

## Matrix Clients You Can Use

Automata works through Matrix, so you can use the chat app your team prefers.

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

## Documentation

- [Demo Guide](docs/DEMO.md)
- [Operations](docs/OPERATIONS.md)
- [Architecture](docs/ARCHITECTURE.md)
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

This is source-available (not OSI open source) and includes commercial restrictions, including limits around third-party hosted and cloud offerings without a separate SentientWave license.

See [LICENSE](LICENSE) for full terms.
