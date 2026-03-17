# QA Strategy

## Quality Priorities
1. Reliability and replay-safe workflow behavior
2. Correctness for orchestration state transitions
3. Adapter interoperability and contract stability
4. Authorization and secret redaction security

## MVP Test Pyramid
- 60-70% unit tests for policy/orchestration decisions
- 20-25% component tests for adapters and workflow store
- 10-15% integration/contract tests with Matrix and Temporal bridges
- Thin E2E smoke tests for core user journeys

## Must-Have CI Gates
- Formatting and lint
- Unit tests
- Adapter contracts
- Determinism/replay checks
- Security baseline scans
