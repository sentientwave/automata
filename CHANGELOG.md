# Changelog

All notable changes to SentientWave Automata are documented in this file.

The format follows Keep a Changelog principles and uses semantic versioning.

## [0.2.16-ce] - 2026-09-29

### Added
- Durable Temporal workflows for organization structure operations, with tracked jobs and API endpoints for checking operation status.
- Organization-chart consistency reconciliation between Automata and Matrix, including account activation and deactivation handling.
- Matrix room management, messaging, directory administration, and organization-operation tools for agents.
- DeepSeek provider support and expanded provider configuration.
- Admin login throttling and a richer organization directory interface.
- Kubernetes deployment support for Element Web and YugabyteDB.

### Changed
- Improved multi-step agent execution, workflow recovery, response grounding, and scheduled-task reconciliation.
- Improved Matrix and Temporal integration and operational status reporting.

### Fixed
- Fixed organization operation resilience and Matrix identity consistency edge cases.

### Security
- Hardened shell-tool environment isolation and admin credential validation.

## [0.1.0] - 2026-03-16

### Added
- Matrix-first collaboration runtime for people and agents
- Temporal durable workflow integration for agent execution
- Directory and Matrix reconciliation APIs
- Podman all-in-one deployment path
- Admin web UI with LLM provider and tool configuration

### Notes
- Initial community release candidate baseline.
