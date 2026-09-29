# Architecture

## Platform Components
- `sentientwave_automata_web`: Phoenix API/UI and ingress surface
- `sentientwave_automata`: orchestration domain, edition gates, adapters, seat manager
- Matrix adapter boundary for inbound/outbound room events
- Temporal adapter boundary for durable workflow execution

## Execution Flow
1. Client posts workflow request to `/api/v1/workflows`.
2. Orchestrator validates payload and entitlement.
3. Temporal adapter starts a durable workflow run.
4. Matrix adapter posts status updates to room(s).
5. Workflow summaries are stored and queryable via API.

## Elixir-First Boundaries
- `SentientwaveAutomata.Orchestrator`
- `SentientwaveAutomata.Policy.Entitlements`
- `SentientwaveAutomata.Adapters.Matrix.*`
- `SentientwaveAutomata.Adapters.Temporal.*`
- `SentientwaveAutomata.Agents.*`

## Temporal Integration
- In-repo Elixir Temporal workers own agent runs, governance proposals, scheduled tasks, and generic conversation workflows
- Phoenix and Matrix stay on the control plane: they persist requests, then start or signal Temporal workflows
- Workflow summaries are stored durably in Postgres for API and admin UI introspection

### Org-Chart Ops: Dedicated, Mandatory Temporal Workflows

**Every agent tool** (`hire_agent`, `fire_agent`, `create/destroy_department`,
`create/destroy_team`, `set_reports_to`, `assign_org_unit`,
`create/delete_matrix_room`, `send_matrix_message`, `search_org_chart`,
`org_job_status`, `system_directory_admin`, `brave_search`, `run_shell`)
**does not access data directly**. Each dispatches a dedicated durable
`SentientwaveAutomata.OrgChart.OpsWorkflow` Temporal workflow, tracked by an
`OrgChart.Job` row (`org_operation_jobs` table):

- `Ops.start/3` returns immediately with the queued job; the returned
  `job_id` (the deterministic Temporal workflow id) is the **continuation** the
  agent uses to check the outcome later.
- The continuation is validated after the fact **via the API** —
  `GET /api/v1/org-jobs/:job_id` (service-auth; also `GET /api/v1/org-jobs`
  to list recent jobs) — or by the agent-facing `org_job_status` tool. Both
  report `completed` + result, `failed` + error, or in-flight + `current_step`.
- Dispatch is **mandatory in production**: when Temporal is unavailable,
  `Ops.start/3` fails the job row and raises
  `SentientwaveAutomata.OrgChart.TemporalUnavailableError` rather than silently
  mutating data inline. The inline fallback (result tagged `"via" => "inline"`)
  is only active in dev/test or when `:org_ops_require_temporal` is `false`.
- The tool's `execute_direct/2` holds the single implementation; the
  `OpsWorkflow` activity reuses it, so the durable path and the inline
  dev/test path never diverge.
- **Freshness-first ops** (`search_org_chart`, `org_job_status`,
  `system_directory_admin`, `brave_search`, `run_shell`) get a unique workflow
  id per call instead of the deterministic idempotency key, so repeated reads,
  status checks, and shell commands observe current state rather than a cached
  result. Mutation ops keep deterministic ids so redelivered tool calls reuse
  the same execution and job row.
- These read/external tools default to `wait: true` (the LLM needs the answer
  inline); pass `"wait": false` to get the `job_id` continuation immediately
  and poll later.
- Enforced by test: every tool in `Agents.Tools.Registry` must have a
  dedicated op in `OrgChart.OpsActivities.supported_ops/0`
  (`org_ops_all_tools_test.exs`).
