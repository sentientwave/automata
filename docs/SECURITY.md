# Security Review

Audited 2026-08-29 (deep-security pass, the production deployment in scope).

Method: full review of the web router + auth plugs, the LLM-facing tool layer
(the widest untrusted-input surface — a remote LLM model picks tool names and
arguments), the Matrix/Synapse integration, the Temporal adapters, the API
controllers, and a dependency audit (`mix hex.audit`). Every finding below was
verified against the running production deployment (single-node k3s) where
applicable.

## Fixed in this pass

| # | Finding | Severity | Fix |
|---|---------|----------|-----|
| 1 | **Dependency CVEs (40+ advisories)**. Vulnerable versions were pinned in `mix.lock`: `phoenix 1.8.5` (2 HIGH: long-poll body splitting, join-flood DoS), `plug 1.19.1` (2 HIGH: multipart header DoS, quadratic query decode), `bandit 1.10.3` (5 HIGH: chunked-body cap ignored, WS reassembly unbounded, CL.CL smuggling), `cowlib 2.13.0` (3 HIGH), `mint 1.7.1` (4 HIGH), `req 0.5.17`, `postgrex 0.22.0` (1 HIGH), `decimal 2.3.0`, `gun 2.1.0` (2 HIGH), `phoenix_live_view 1.1.27`, `hpax 1.0.3`. | HIGH | Upgraded: phoenix 1.8.13, plug 1.20.3, bandit 1.12.5, cowlib 2.19.0, mint 1.9.3, req 0.7.4, postgrex 0.22.4, decimal 3.1.1, gun 2.5.0, phoenix_live_view 1.1.33, hpax 1.0.4, ecto 3.14.2, tzdata 1.1.4. **Advisories down from 40+ to 8** (see "Residual" below). |
| 2 | **`temporal_sdk 0.1.17` pinned old gun/cowlib and had its own CVE surface**. | MEDIUM | Upgraded to `temporal_sdk 0.2.20`; adapted 3 call sites (`wait_one/1` to `wait_any/1` in `governance/proposal_workflow.ex`, `agents/scheduled_task_workflow.ex`, `agents/workflow.ex`; `TemporalSdk.Service.signal_workflow` to `TemporalSdk.signal_workflow` in `adapters/temporal/runtime.ex`). Added a `gun` override (`>= 2.2.0 and < 3.0.0`) in both apps so the SDK's `~> 2.2.0` pin does not drag 2.2.x back in. |
| 3 | **`run_shell` leaked the pod environment**. `System.cmd("/bin/sh", ["-lc", cmd])` inherited the full BEAM environment — `SECRET_KEY_BASE`, `AUTOMATA_API_TOKEN`, the LLM provider key — and the LLM picks the command, so a single `printenv` (or a prompt injection telling it to) dumped every pod secret into the LLM context and Matrix. Compounding detail: Erlang's `:env` port option *extends* the inherited environment rather than replacing it, so `System.cmd(env:)` alone does not restrict. | HIGH (when the tool is granted) | Command now runs under `/usr/bin/env -i PATH=... HOME=... <cmd>` (exact-replacement env). Default set: `PATH HOME USER LANG LC_ALL TZ`; deployments widen it with `AUTOMATA_RUN_SHELL_ENV` (comma-separated). Regression tests: `test/sentientwave_automata/agents/tools/run_shell_env_test.exs`. Note: in the production deployment `run_shell` currently has *no* `tool_configs` row, so no agent can see it yet — the fix matters the moment the row is added. |
| 4 | **Admin console accepted a blank password in production**. `AdminAuth.expected_password/0` returns `""` in prod when `AUTOMATA_WEB_ADMIN_PASSWORD` is unset, and `authenticate/2` compares against it — so `(expected_user, "")` logged in. The login template showed a warning banner but the server did not reject. | MEDIUM | `AdminAuth.valid_credentials?/2` now fails closed when the expected password is empty **and** `:prod` **and** local fallbacks are not allowed (`AUTOMATA_ALLOW_LOCAL_FALLBACKS`). The production deployment is unaffected (password set + fallbacks allowed). Test: `session_controller_test.exs` ("rejects blank password in production"). |
| 5 | **No brute-force throttle on the admin login** (the only non-service credential endpoint; live in prod). | MEDIUM | `SentientwaveAutomataWeb.Plugs.LoginThrottle`: per-IP rolling 15-minute window (default max 10, `AUTOMATA_LOGIN_MAX_ATTEMPTS`), checked on `POST /login` before and after credential verification. Tests: `login_throttle_test.exs` (unit) + `session_controller_test.exs` (controller). |
| 6 | **`GET /api/v1/agent-memories/search` 500'd on non-integer `top_k`** (`String.to_integer` raises). | LOW | `parse_top_k/1` (`Integer.parse`, default 5, clamped to 50). Test: `agent_memories_controller_test.exs`. |
| 7 | **`brave_search` api_token persisted in clear in `org_operation_jobs.args`** (Postgres, any DB reader). | MEDIUM | `OrgChart.Jobs.create_or_get/1` masks `args["api_token"]` to `"***"` on persistence (runtime arg is unmasked). Test: `org_chart_jobs_test.exs`. |

## Verified safe (checked, no change needed)

- `Directory.list_users/1` (used by `system_directory_admin.list_directory`) returns
  `to_public_user` structs — the password field is **not** exposed.
- `POST /api/v1/onboarding/user` is idempotent on `name` (`ON CONFLICT (name) DO
  UPDATE SET password = EXCLUDED.password`) — an unauthenticated repeat call
  with a fresh password would rotate the existing user's login, but the caller
  must already know the `name` and accept the write-through; acceptable for the
  onboarding flow, noted for hardening.
- `POST /api/v1/sessions` (agent logins) verifies `password` (plaintext compare);
  the Matrix adapter login uses the dedicated admin reader with a hashed
  password (`admin/argon2` in `federation_configs`).
- `RequireServiceAuth` uses `Plug.Crypto.secure_compare` (timing-safe) against a
  single expected token; `RequireSameOrigin` checks `Origin`/`Referer` against
  `conn.host`.
- LLM `llm_traces` store full prompts/responses **without** auth headers (the key
  is sent in the `Authorization` header, never serialized); trace writes are
  best-effort (`:telemetry` span end).
- Req-based LLM calls use TLS verification + 60s connect / 300s request timeouts.
- Matrix `enable_registration: false`; federation is empty by default; the
  poller auto-accepts room invites **for the admin reader only**.

## Residual advisories after the upgrade (`mix hex.audit`, 8)

| Package | Version | Notes |
|---------|---------|-------|
| gun | 2.5.0 | 1 MEDIUM (HTTP request splitting via CONTINUATION) — shared with cowboy; fixed in a future release. |
| hackney | 1.25.0 | 1 HIGH (SOCKS5+TLS hang), 2 MEDIUM, 1 LOW — pulled in by `tzdata` only; the app does not use hackney's SOCKS5 path. |
| cowlib | 2.19.0 | 2 MEDIUM + 1 LOW — already the latest release; fixed in a future release. |

`tzdata` (→ `hackney`) is the only runtime dependency that keeps hackney around
(timezone fetch at startup, HTTPS to `iana.org`); none of the advisories sit on
a hot path.

## Findings left open (deployment-level, production)

Severity assumes the node is a **trusted private network behind NAT**, with
the Tailscale tailnet as the intended primary access path.

1. **Temporal gRPC + Web UI are unauthenticated** (exposed via NodePorts) —
   `temporal-server` runs without mTLS/client auth, and the UI has no auth of
   its own. Any LAN client can read **all** workflow history (agent tool calls
   and arguments — potentially including LLM keys) via the gRPC API, and
   *signal/terminate* workflows (state mutation). **HIGH on a hostile LAN.** The UI is commonly
   linked via a NodePort URL in the Helm values file; keep it reachable for
   the operator in the interim, but long-term bind it to Tailscale only or
   put an auth proxy in front.
2. **Local LLM server (e.g. vLLM) bound to `0.0.0.0` and guarded by a short
   token** (see the `llm_provider_configs.api_token` row). LAN clients can
   consume the model and send prompts (cost + side-channel).
   **Recommendation**: strong `--api-key` on the host LLM service + update the
   `llm_provider_configs.api_token` row.
3. **Postgres `postgres/postgres`** in the Helm values (local data volume).
   Rotate before leaving the trusted network.
4. **Secrets in plaintext in the (untracked) Helm values file** (the deployment's
   `k8s-values.yaml`): `SECRET_KEY_BASE`, Matrix admin password, API token, admin password,
   LLM key. The values file is the single source — a backup leak leaks all
   secrets. **Recommendation**: migrate to a k8s `Secret` (e.g. via `envFromSecrets`
   for the LLM key) and keep the values file git-ignored with `chmod 600`.
5. **`AUTOMATA_ALLOW_LOCAL_FALLBACKS=true` in production** disables the
   prod-strict runtime validation (matrix adapter, DB check, etc.). It is commonly
   set to allow a local LLM provider; re-evaluate once provider selection
   stabilizes.
6. **Admin password == Matrix admin password** (reusing one value for
   `AUTOMATA_WEB_ADMIN_PASSWORD` and `MATRIX_ADMIN_PASSWORD`) — one leak
   compromises both.
7. **`session_token` cookie without `secure` flag** — fine over LAN/Tailscale
   HTTPS; set `secure: true` if the console is ever exposed publicly.
8. **`DirectoryUser.changeset` has no `validate_format`/length on `password`** —
   a service-token caller (or onboarding endpoint) can set a 1-char password.
   The directory is the LLM's user-creation surface (`hire_agent` →
   `Directory.create_user`).
9. **`conversation_scope` / `sender_mxid` are caller-supplied** in the LLM chat
   API — an agent can impersonate any sender to the model (context poisoning,
   not data access). Documented as accepted for now.
10. **`agent_memories` are per-`(agent_id, memory_type)` with no cross-agent
    ACL** — the search endpoint is service-auth only, so any service holder can
    read any agent's memories.

## Notes

- Plaintext password storage (`directory_users.password`,
  `llm_provider_configs.api_token`) is a known base-repo simplification;
  `argon2` exists in `federation_configs` for Matrix but is not used for the
  directory yet.
- The `run_shell` + `system_directory_admin` tools are **dormant** in the
  production deployment (no `tool_configs` rows) but **granted** to some agents
  (permission rows exist). Either is one row-add away from being LLM-visible.
- Temporal **externalizer null round-trip** (JSON codec maps JSON `null` to the
  `:null` atom, and `nil` round-trips as the string `"nil"`/`"null"`) is
  handled in `org_chart/temporal_workflow.ex` (`normalize_external/1`,
  `presence/1`, `string_arg/2`) — a data-integrity fix that also matters for
  `:null`-bearing LLM inputs.
