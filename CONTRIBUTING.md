# Contributing

Thanks for your interest in SentientWave Automata.

## Important License Notice

Before contributing, read [LICENSE](LICENSE).

This project is distributed under the SentientWave Community Source License. Contributions are accepted under the same license terms, including restrictions on modification/redistribution/commercial hosting unless separately licensed by SentientWave Inc.

By submitting a contribution, you represent that:
- you have the legal right to submit it,
- the contribution is your original work (or you have permission to submit it), and
- you agree your contribution may be used by SentientWave Inc. under the project license and related commercial licenses.

## Development Setup

```bash
mix deps.get
mix compile
mix phx.server
```

## Quality Checks

Run before opening a PR:

```bash
mix format
mix compile
mix test
```

For container scripts:

```bash
bash -n deploy/all-in-one/bin/*.sh deploy/all-in-one/scripts/*.sh scripts/demo/*.sh
```

## Pull Request Guidelines

- Keep PRs focused and small when possible.
- Include a clear problem statement and proposed solution.
- Update docs when behavior, APIs, or operations change.
- Add or update tests for the changed behavior.
- Do not include secrets or credentials in code, docs, or screenshots.

## Commit Message Suggestions

Use concise, imperative commit messages, for example:
- `add matrix directory reconcile API`
- `fix matrix provisioning login fallback`
- `update all-in-one deployment docs`

## Reporting Vulnerabilities

Do not open public issues for security vulnerabilities.

Please follow [SECURITY.md](SECURITY.md).
