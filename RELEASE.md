# Release Process

This document defines the baseline release flow for SentientWave Automata Community Edition.

## 1. Prepare Release Candidate

1. Ensure `main` is green locally.
2. Confirm release notes are updated in [CHANGELOG.md](CHANGELOG.md).
3. Set version in [VERSION](VERSION).
4. Verify docs updates for any API or operational changes.

## 2. Quality Gates

Run:

```bash
mix format
mix compile
mix test
bash -n deploy/all-in-one/bin/*.sh deploy/all-in-one/scripts/*.sh
```

Recommended extra checks:

```bash
mix deps.unlock --check-unused
```

## 3. Container Validation

1. Build all-in-one image.
2. Start container and complete onboarding.
3. Validate:
   - admin login
   - Matrix connectivity
   - mention-triggered agent run
   - agent response in Matrix room
   - upgrade flow preserves data/session behavior

## 4. Tag And Publish

1. Commit release changes (`VERSION`, `CHANGELOG.md`, docs).
2. Create annotated tag matching `VERSION`.
3. Push branch and tag.
4. Publish release notes from changelog entry.

## 5. Post-Release Verification

1. Pull published artifacts and perform smoke test.
2. Validate upgrade from previous stable release.
3. Track regressions in GitHub issues with release label.

## 6. Hotfix Procedure

1. Branch from latest release tag.
2. Apply minimal fix plus tests.
3. Bump patch version.
4. Update `CHANGELOG.md`.
5. Retag and publish.

