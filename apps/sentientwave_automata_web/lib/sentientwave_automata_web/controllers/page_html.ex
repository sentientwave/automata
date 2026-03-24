defmodule SentientwaveAutomataWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use SentientwaveAutomataWeb, :html

  alias SentientwaveAutomata.Settings
  alias SentientwaveAutomataWeb.Layouts

  @llm_provider_ui_copy %{
    "local" => %{
      label: "Local (Fallback)",
      family: "Built-in fallback",
      summary: "Use the local fallback path for development and break-glass testing.",
      auth_header: "none",
      token_label: "API Token",
      token_help: "The local fallback usually does not need an API token.",
      model_help: "Use a local alias or keep the default fallback model.",
      endpoint_help:
        "Leave Base URL blank unless you are routing through a local compatibility layer."
    },
    "openai" => %{
      label: "OpenAI",
      family: "Chat Completions API",
      summary: "Use OpenAI hosted models through the standard OpenAI API surface.",
      auth_header: "Authorization: Bearer",
      token_label: "OpenAI API Key",
      token_help: "Paste an OpenAI API key. Automata sends it as a Bearer token.",
      model_help: "Recommended starter model: gpt-4o-mini.",
      endpoint_help: "Leave Base URL blank to use the default OpenAI API endpoint."
    },
    "gemini" => %{
      label: "Google Gemini",
      family: "Gemini generateContent API",
      summary: "Use Gemini models through Google's native Gemini REST API.",
      auth_header: "x-goog-api-key",
      token_label: "Gemini API Key",
      token_help:
        "Create a Gemini API key in Google AI Studio. Automata sends it in the x-goog-api-key header.",
      model_help: "Recommended starter model: gemini-2.5-flash.",
      endpoint_help:
        "Leave Base URL blank to use the standard Gemini REST endpoint, or set a compatible proxy."
    },
    "anthropic" => %{
      label: "Anthropic",
      family: "Messages API",
      summary: "Use Claude models through Anthropic's Messages API.",
      auth_header: "x-api-key",
      token_label: "Anthropic API Key",
      token_help: "Paste an Anthropic API key. Automata sends it as x-api-key.",
      model_help: "Recommended starter model: claude-3-5-haiku-latest.",
      endpoint_help: "Leave Base URL blank to use the default Anthropic API endpoint."
    },
    "cerebras" => %{
      label: "Cerebras",
      family: "Chat Completions API",
      summary: "Use Cerebras hosted models with the Cerebras chat completions endpoint.",
      auth_header: "Authorization: Bearer",
      token_label: "Cerebras API Key",
      token_help: "Paste a Cerebras API key. Automata sends it as a Bearer token.",
      model_help: "Recommended starter model: gpt-oss-120b.",
      endpoint_help: "Leave Base URL blank to use the default Cerebras API endpoint."
    },
    "openrouter" => %{
      label: "OpenRouter",
      family: "OpenAI-compatible API",
      summary: "Route model traffic through OpenRouter with OpenAI-style request semantics.",
      auth_header: "Authorization: Bearer",
      token_label: "OpenRouter API Key",
      token_help: "Paste an OpenRouter API key. Automata sends it as a Bearer token.",
      model_help: "Recommended starter model: openai/gpt-4o-mini.",
      endpoint_help: "Leave Base URL blank to use the default OpenRouter API endpoint."
    },
    "lm-studio" => %{
      label: "LM Studio",
      family: "Local OpenAI-compatible API",
      summary: "Use a self-hosted LM Studio server for local or private model inference.",
      auth_header: "optional",
      token_label: "API Token",
      token_help: "LM Studio usually does not require a token unless you configured one locally.",
      model_help: "Set the local model alias served by your LM Studio instance.",
      endpoint_help:
        "Point Base URL at your LM Studio server if you are not using the default local endpoint."
    },
    "ollama" => %{
      label: "Ollama",
      family: "Local Ollama API",
      summary: "Use a self-hosted Ollama runtime for local model inference.",
      auth_header: "optional",
      token_label: "API Token",
      token_help:
        "Ollama usually does not require a token unless you front it with another gateway.",
      model_help: "Set the Ollama model name you want the provider to use.",
      endpoint_help:
        "Point Base URL at your Ollama server if you are not using the default local endpoint."
    }
  }

  attr :flash, :map, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: ""
  attr :status, :map, required: true
  attr :admin_user, :string, required: true
  attr :nav, :list, required: true
  slot :inner_block, required: true

  def admin_shell(assigns) do
    ~H"""
    <Layouts.flash_group flash={@flash} />

    <div class="sw-admin-shell">
      <aside class="sw-sidebar">
        <div class="sw-brand">
          <p class="sw-brand-kicker">SentientWave Automata</p>
          <h2 class="sw-brand-title">{@status.company_name}</h2>
          <p class="sw-brand-subtitle">{@status.group_name}</p>
        </div>

        <nav class="sw-nav" aria-label="Admin navigation">
          <%= for item <- @nav do %>
            <a href={item.href} class={["sw-nav-link", item.active && "is-active"]}>
              {item.label}
            </a>
          <% end %>
        </nav>

        <div class="sw-sidebar-meta">
          <p>Admin: <strong>{@admin_user}</strong></p>
          <p>Source: <strong>{@status.source}</strong></p>
          <p>Homeserver: <strong>{@status.homeserver_domain}</strong></p>
        </div>

        <div class="sw-sidebar-theme">
          <p class="sw-sidebar-section-title">Appearance</p>
          <Layouts.theme_toggle />
        </div>

        <form action={~p"/logout"} method="post" class="sw-sidebar-logout">
          <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
          <input type="hidden" name="_method" value="delete" />
          <button type="submit" class="sw-btn sw-btn-ghost sw-btn-block">Sign Out</button>
        </form>
      </aside>

      <main class="sw-main">
        <header class="sw-page-header">
          <div>
            <p class="sw-page-kicker">Internal Admin Console</p>
            <h1 class="sw-page-title">{@title}</h1>
            <p :if={@subtitle != ""} class="sw-page-subtitle">{@subtitle}</p>
          </div>

          <div class="sw-status-row">
            <span class={["sw-pill", service_class(@status.services.automata)]}>
              Automata: {@status.services.automata}
            </span>
            <span class={["sw-pill", service_class(@status.services.matrix)]}>
              Matrix: {@status.services.matrix}
            </span>
            <span class={["sw-pill", service_class(@status.services.temporal_ui)]}>
              Temporal: {@status.services.temporal_ui}
            </span>
          </div>
        </header>

        <section class="sw-main-content">
          {render_slot(@inner_block)}
        </section>
      </main>
    </div>
    """
  end

  attr :provider, :string, required: true

  def provider_setup_panel(assigns) do
    setup = llm_provider_setup(assigns.provider)

    assigns =
      assigns
      |> assign(:setup, setup)
      |> assign(:catalog_json, llm_provider_setup_catalog_json())

    ~H"""
    <section
      class="sw-card sw-provider-guide"
      data-provider-guide
      data-provider-catalog={@catalog_json}
    >
      <div class="sw-provider-guide-header">
        <div>
          <p class="sw-section-label">Provider Setup</p>
          <h2 class="sw-card-title" data-provider-guide-title>{@setup.label}</h2>
          <p class="sw-card-copy" data-provider-guide-summary>{@setup.summary}</p>
        </div>

        <span class="sw-pill is-ok" data-provider-guide-family>{@setup.family}</span>
      </div>

      <div class="sw-kpi-grid sw-provider-guide-grid mt-5">
        <article class="sw-kpi-card">
          <p class="sw-kpi-label">Default Model</p>
          <p class="sw-kpi-value sw-kpi-value-small" data-provider-guide-model>
            {@setup.default_model}
          </p>
        </article>

        <article class="sw-kpi-card">
          <p class="sw-kpi-label">Default Endpoint</p>
          <p class="sw-kpi-value sw-kpi-value-small" data-provider-guide-endpoint>
            {@setup.default_base_url_label}
          </p>
        </article>

        <article class="sw-kpi-card">
          <p class="sw-kpi-label">Auth Mode</p>
          <p class="sw-kpi-value sw-kpi-value-small" data-provider-guide-auth>
            {@setup.auth_header}
          </p>
        </article>
      </div>

      <div class="sw-stack mt-5">
        <div class="sw-alert sw-alert-warning" data-provider-guide-token-help>
          {@setup.token_help}
        </div>
        <p class="sw-card-copy" data-provider-guide-model-help>{@setup.model_help}</p>
        <p class="sw-card-copy" data-provider-guide-endpoint-help>{@setup.endpoint_help}</p>
      </div>
    </section>
    """
  end

  def trace_status_class("ok"), do: "is-ok"
  def trace_status_class("error"), do: "is-issue"
  def trace_status_class(_), do: "is-neutral"

  def format_timestamp(%DateTime{} = timestamp) do
    Calendar.strftime(timestamp, "%Y-%m-%d %H:%M:%S UTC")
  end

  def format_timestamp(_), do: "not recorded"

  def trace_requester_name(trace) do
    cond do
      present?(trace.requester_display_name) -> trace.requester_display_name
      present?(trace.requester_localpart) -> trace.requester_localpart
      present?(trace.requester_mxid) -> trace.requester_mxid
      true -> "Unknown requester"
    end
  end

  def trace_requester_meta(trace) do
    [trace.requester_kind, trace.requester_mxid]
    |> Enum.filter(&present?/1)
    |> Enum.join(" · ")
  end

  def trace_preview(trace) do
    request_preview = request_message_preview(trace)
    response_preview = get_in(trace.response_payload || %{}, ["content"])
    error_preview = get_in(trace.error_payload || %{}, ["reason"])

    cond do
      present?(request_preview) -> truncate_text(request_preview, 140)
      present?(response_preview) -> truncate_text(response_preview, 140)
      present?(error_preview) -> truncate_text(error_preview, 140)
      true -> "No preview available."
    end
  end

  def trace_duration(trace) do
    case {trace.requested_at, trace.completed_at} do
      {%DateTime{} = requested_at, %DateTime{} = completed_at} ->
        diff = DateTime.diff(completed_at, requested_at, :millisecond)
        "#{max(diff, 0)} ms"

      _ ->
        "n/a"
    end
  end

  def pretty_json(nil), do: "No payload recorded."

  def pretty_json(payload) do
    Jason.encode!(payload, pretty: true)
  rescue
    _ -> inspect(payload, pretty: true, limit: :infinity)
  end

  def active_designation_count(skill) do
    skill.designations
    |> Enum.count(&(&1.status == :active))
  end

  def designation_status_class(:active), do: "is-ok"
  def designation_status_class(:rolled_back), do: "is-neutral"
  def designation_status_class(_), do: "is-neutral"

  def skill_summary(skill) do
    skill.metadata
    |> Map.get("summary", "")
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> "No summary added yet."
    end
  end

  def skill_tags(skill) do
    skill.metadata
    |> Map.get("tags", [])
    |> case do
      tags when is_list(tags) -> tags
      _ -> []
    end
  end

  def skill_tools(skill) do
    skill.metadata
    |> Map.get("tools", [])
    |> case do
      tools when is_list(tools) -> tools
      _ -> []
    end
  end

  def designation_agent_name(designation) do
    agent = designation.agent
    display_name = agent && agent.display_name
    slug = agent && agent.slug

    cond do
      present?(display_name) -> display_name
      present?(slug) -> slug
      true -> "Unknown agent"
    end
  end

  def directory_kind_label(:person), do: "Human"
  def directory_kind_label("person"), do: "Human"
  def directory_kind_label(:agent), do: "Agent"
  def directory_kind_label("agent"), do: "Agent"
  def directory_kind_label(:service), do: "Service"
  def directory_kind_label("service"), do: "Service"
  def directory_kind_label(_), do: "Unknown"

  def directory_kind_class(:person), do: "is-neutral"
  def directory_kind_class("person"), do: "is-neutral"
  def directory_kind_class(:agent), do: "is-ok"
  def directory_kind_class("agent"), do: "is-ok"
  def directory_kind_class(:service), do: "is-warning"
  def directory_kind_class("service"), do: "is-warning"
  def directory_kind_class(_), do: "is-neutral"

  def operational_status_class(:online), do: "is-ok"
  def operational_status_class(:offline), do: "is-issue"
  def operational_status_class(_), do: "is-neutral"

  def tool_state_class(true), do: "is-ok"
  def tool_state_class(false), do: "is-issue"
  def tool_state_class(_), do: "is-neutral"

  def tool_state_label(%{effective_allowed: true}), do: "Allowed"
  def tool_state_label(%{effective_allowed: false}), do: "Blocked"
  def tool_state_label(_), do: "Unknown"

  def llm_provider_label(provider) do
    provider
    |> llm_provider_setup()
    |> Map.fetch!(:label)
  end

  def llm_provider_setup(provider) do
    normalized = normalize_llm_provider(provider)
    defaults = Settings.llm_provider_defaults(normalized)

    @llm_provider_ui_copy
    |> Map.get(normalized, @llm_provider_ui_copy["local"])
    |> Map.merge(%{
      provider: normalized,
      default_model: defaults.model,
      default_base_url: defaults.base_url,
      default_base_url_label:
        case defaults.base_url do
          value when is_binary(value) and value != "" -> value
          _ -> "Provider default / not required"
        end
    })
  end

  def llm_provider_setup_catalog_json do
    @llm_provider_ui_copy
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(%{}, fn provider, acc ->
      Map.put(acc, provider, llm_provider_setup(provider))
    end)
    |> Jason.encode!()
  end

  def governance_law_kind_label(:general), do: "General"
  def governance_law_kind_label("general"), do: "General"
  def governance_law_kind_label(:voting_policy), do: "Voting Policy"
  def governance_law_kind_label("voting_policy"), do: "Voting Policy"
  def governance_law_kind_label(_), do: "Unknown"

  def governance_law_status_label(:active), do: "Active"
  def governance_law_status_label("active"), do: "Active"
  def governance_law_status_label(:repealed), do: "Repealed"
  def governance_law_status_label("repealed"), do: "Repealed"
  def governance_law_status_label(_), do: "Unknown"

  def governance_proposal_type_label(:create), do: "Create"
  def governance_proposal_type_label("create"), do: "Create"
  def governance_proposal_type_label(:amend), do: "Amend"
  def governance_proposal_type_label("amend"), do: "Amend"
  def governance_proposal_type_label(:repeal), do: "Repeal"
  def governance_proposal_type_label("repeal"), do: "Repeal"
  def governance_proposal_type_label(_), do: "Proposal"

  def governance_proposal_status_label(:open), do: "Open"
  def governance_proposal_status_label("open"), do: "Open"
  def governance_proposal_status_label(:approved), do: "Approved"
  def governance_proposal_status_label("approved"), do: "Approved"
  def governance_proposal_status_label(:rejected), do: "Rejected"
  def governance_proposal_status_label("rejected"), do: "Rejected"
  def governance_proposal_status_label(:cancelled), do: "Cancelled"
  def governance_proposal_status_label("cancelled"), do: "Cancelled"
  def governance_proposal_status_label(_), do: "Unknown"

  def governance_vote_choice_label(:approve), do: "Approve"
  def governance_vote_choice_label("approve"), do: "Approve"
  def governance_vote_choice_label(:reject), do: "Reject"
  def governance_vote_choice_label("reject"), do: "Reject"
  def governance_vote_choice_label(:abstain), do: "Abstain"
  def governance_vote_choice_label("abstain"), do: "Abstain"
  def governance_vote_choice_label(_), do: "Unknown"

  def governance_role_status_label(true), do: "Enabled"
  def governance_role_status_label("true"), do: "Enabled"
  def governance_role_status_label(:active), do: "Enabled"
  def governance_role_status_label("active"), do: "Enabled"
  def governance_role_status_label(false), do: "Disabled"
  def governance_role_status_label("false"), do: "Disabled"
  def governance_role_status_label(:revoked), do: "Disabled"
  def governance_role_status_label("revoked"), do: "Disabled"
  def governance_role_status_label(_), do: "Unknown"

  def governance_law_status_class(:active), do: "is-ok"
  def governance_law_status_class("active"), do: "is-ok"
  def governance_law_status_class(:repealed), do: "is-neutral"
  def governance_law_status_class("repealed"), do: "is-neutral"
  def governance_law_status_class(_), do: "is-neutral"

  def governance_proposal_status_class(:open), do: "is-warning"
  def governance_proposal_status_class("open"), do: "is-warning"
  def governance_proposal_status_class(:approved), do: "is-ok"
  def governance_proposal_status_class("approved"), do: "is-ok"
  def governance_proposal_status_class(:rejected), do: "is-issue"
  def governance_proposal_status_class("rejected"), do: "is-issue"
  def governance_proposal_status_class(:cancelled), do: "is-neutral"
  def governance_proposal_status_class("cancelled"), do: "is-neutral"
  def governance_proposal_status_class(_), do: "is-neutral"

  def governance_role_status_class(true), do: "is-ok"
  def governance_role_status_class("true"), do: "is-ok"
  def governance_role_status_class(:active), do: "is-ok"
  def governance_role_status_class("active"), do: "is-ok"
  def governance_role_status_class(false), do: "is-neutral"
  def governance_role_status_class("false"), do: "is-neutral"
  def governance_role_status_class(:revoked), do: "is-neutral"
  def governance_role_status_class("revoked"), do: "is-neutral"
  def governance_role_status_class(_), do: "is-neutral"

  def governance_vote_choice_class(:approve), do: "is-ok"
  def governance_vote_choice_class("approve"), do: "is-ok"
  def governance_vote_choice_class(:reject), do: "is-issue"
  def governance_vote_choice_class("reject"), do: "is-issue"
  def governance_vote_choice_class(:abstain), do: "is-neutral"
  def governance_vote_choice_class("abstain"), do: "is-neutral"
  def governance_vote_choice_class(_), do: "is-neutral"

  def governance_law_summary(law) do
    body = Map.get(law, :markdown_body, Map.get(law, "markdown_body", ""))

    body =
      cond do
        is_binary(body) -> body
        is_nil(body) -> ""
        true -> to_string(body)
      end

    body
    |> String.split("\n", trim: true)
    |> Enum.find_value("No law body recorded yet.", fn line ->
      trimmed = String.trim(line)

      if trimmed == "" do
        nil
      else
        truncate_text(trimmed, 140)
      end
    end)
  end

  def governance_snapshot_label(nil), do: "No snapshot published yet"

  def governance_snapshot_label(snapshot) when is_map(snapshot) do
    version = Map.get(snapshot, :version, Map.get(snapshot, "version", "unknown"))
    published_at = Map.get(snapshot, :published_at, Map.get(snapshot, "published_at"))

    case published_at do
      %DateTime{} = timestamp ->
        "Version #{version} published #{format_timestamp(timestamp)}"

      _ ->
        "Version #{version}"
    end
  end

  def governance_snapshot_label(_), do: "Unknown snapshot"

  def governance_member_label(member) when is_map(member) do
    display_name =
      Map.get(member, :display_name, Map.get(member, "display_name", ""))

    localpart = Map.get(member, :localpart, Map.get(member, "localpart", ""))

    cond do
      present?(display_name) and present?(localpart) -> "#{display_name} (#{localpart})"
      present?(display_name) -> display_name
      present?(localpart) -> localpart
      true -> "Unknown member"
    end
  end

  def governance_role_assignment_name(assignment) when is_map(assignment) do
    user = Map.get(assignment, :user, Map.get(assignment, "user"))
    governance_member_label(user || %{})
  end

  def governance_role_assignment_active?(assignment) when is_map(assignment) do
    Map.get(assignment, :status, Map.get(assignment, "status", :active)) in [:active, "active"]
  end

  def governance_vote_tally_label(%{approve: approve, reject: reject, abstain: abstain}) do
    "Approve #{approve} · Reject #{reject} · Abstain #{abstain}"
  end

  def governance_vote_tally_label(%{} = tally) do
    approve = Map.get(tally, :approve, Map.get(tally, "approve", 0))
    reject = Map.get(tally, :reject, Map.get(tally, "reject", 0))
    abstain = Map.get(tally, :abstain, Map.get(tally, "abstain", 0))

    "Approve #{approve} · Reject #{reject} · Abstain #{abstain}"
  end

  def governance_vote_tally_label(_), do: "No votes recorded"

  def governance_rule_label(rule_config) when is_map(rule_config) do
    mode = Map.get(rule_config, :approval_mode, Map.get(rule_config, "approval_mode", "majority"))
    quorum = Map.get(rule_config, :quorum_percent, Map.get(rule_config, "quorum_percent", 50))

    threshold =
      Map.get(
        rule_config,
        :approval_threshold_percent,
        Map.get(rule_config, "approval_threshold_percent", 51)
      )

    hours =
      Map.get(rule_config, :voting_window_hours, Map.get(rule_config, "voting_window_hours", 72))

    "#{mode}, quorum #{quorum}%, approval threshold #{threshold}%, window #{hours}h"
  end

  def governance_rule_label(_), do: "No voting rule configured"

  def governance_bool_label(true), do: "Yes"
  def governance_bool_label(false), do: "No"
  def governance_bool_label(_), do: "Unknown"

  def scheduled_task_type_label(:run_agent_prompt), do: "Run Agent Prompt"
  def scheduled_task_type_label("run_agent_prompt"), do: "Run Agent Prompt"
  def scheduled_task_type_label(:post_room_message), do: "Post Room Message"
  def scheduled_task_type_label("post_room_message"), do: "Post Room Message"
  def scheduled_task_type_label(_), do: "Task"

  def scheduled_task_schedule_label(task) do
    interval = Map.get(task, :schedule_interval) || Map.get(task, "schedule_interval") || 1
    minute = pad_time(Map.get(task, :schedule_minute) || Map.get(task, "schedule_minute") || 0)
    hour = pad_time(Map.get(task, :schedule_hour) || Map.get(task, "schedule_hour") || 0)
    timezone = Map.get(task, :timezone) || Map.get(task, "timezone") || "Etc/UTC"

    case Map.get(task, :schedule_type) || Map.get(task, "schedule_type") do
      :hourly ->
        "Every #{interval} hour(s) at minute #{minute} (#{timezone})"

      "hourly" ->
        "Every #{interval} hour(s) at minute #{minute} (#{timezone})"

      :daily ->
        "Every #{interval} day(s) at #{hour}:#{minute} (#{timezone})"

      "daily" ->
        "Every #{interval} day(s) at #{hour}:#{minute} (#{timezone})"

      :weekly ->
        weekday =
          weekday_label(Map.get(task, :schedule_weekday) || Map.get(task, "schedule_weekday"))

        "Every #{interval} week(s) on #{weekday} at #{hour}:#{minute} (#{timezone})"

      "weekly" ->
        weekday =
          weekday_label(Map.get(task, :schedule_weekday) || Map.get(task, "schedule_weekday"))

        "Every #{interval} week(s) on #{weekday} at #{hour}:#{minute} (#{timezone})"

      _ ->
        "Schedule not configured"
    end
  end

  def metadata_json(nil), do: "{}"

  def metadata_json(value) when is_map(value) do
    Jason.encode!(value, pretty: true)
  rescue
    _ -> "{}"
  end

  def metadata_json(_), do: "{}"

  def matrix_credentials_present?(nil), do: false

  def matrix_credentials_present?(credentials) when is_map(credentials) do
    localpart = Map.get(credentials, "localpart", Map.get(credentials, :localpart))
    mxid = Map.get(credentials, "mxid", Map.get(credentials, :mxid))
    password = Map.get(credentials, "password", Map.get(credentials, :password))

    Enum.all?([localpart, mxid, password], fn
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end)
  end

  def last_outcome_label(nil), do: "No runs yet"

  def last_outcome_label(outcome) when is_map(outcome) do
    outcome
    |> Map.get("status", "unknown")
    |> case do
      "ok" -> "Last run succeeded"
      "error" -> "Last run failed"
      other -> "Last run: #{other}"
    end
  end

  attr :task, :map, default: %{}
  attr :action, :string, required: true
  attr :title, :string, required: true
  attr :submit_label, :string, required: true
  attr :task_type_options, :list, required: true
  attr :schedule_options, :list, required: true
  attr :weekday_options, :list, required: true

  def scheduled_task_form(assigns) do
    ~H"""
    <form action={@action} method="post" class="sw-form-grid mt-5">
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <input type="hidden" name="task[enabled]" value="false" />

      <label class="sw-field">
        <span>Name</span>
        <input
          name="task[name]"
          class="sw-input"
          value={Map.get(@task, :name) || Map.get(@task, "name", "")}
        />
      </label>

      <label class="sw-field">
        <span>Task Type</span>
        <select name="task[task_type]" class="sw-select">
          <%= for {label, value} <- @task_type_options do %>
            <option
              value={value}
              selected={
                to_string(
                  Map.get(@task, :task_type) || Map.get(@task, "task_type", "run_agent_prompt")
                ) ==
                  value
              }
            >
              {label}
            </option>
          <% end %>
        </select>
      </label>

      <label class="sw-checkbox-row">
        <input
          type="checkbox"
          name="task[enabled]"
          value="true"
          checked={Map.get(@task, :enabled, Map.get(@task, "enabled", true))}
        />
        <span>Enabled</span>
      </label>

      <label class="sw-field">
        <span>Schedule Type</span>
        <select name="task[schedule_type]" class="sw-select">
          <%= for {label, value} <- @schedule_options do %>
            <option
              value={value}
              selected={
                to_string(Map.get(@task, :schedule_type) || Map.get(@task, "schedule_type", "daily")) ==
                  value
              }
            >
              {label}
            </option>
          <% end %>
        </select>
      </label>

      <label class="sw-field">
        <span>Interval</span>
        <input
          name="task[schedule_interval]"
          class="sw-input"
          type="number"
          min="1"
          value={Map.get(@task, :schedule_interval) || Map.get(@task, "schedule_interval", 1)}
        />
      </label>

      <label class="sw-field">
        <span>Hour</span>
        <input
          name="task[schedule_hour]"
          class="sw-input"
          type="number"
          min="0"
          max="23"
          value={Map.get(@task, :schedule_hour) || Map.get(@task, "schedule_hour", "")}
        />
      </label>

      <label class="sw-field">
        <span>Minute</span>
        <input
          name="task[schedule_minute]"
          class="sw-input"
          type="number"
          min="0"
          max="59"
          value={Map.get(@task, :schedule_minute) || Map.get(@task, "schedule_minute", 0)}
        />
      </label>

      <label class="sw-field">
        <span>Weekday</span>
        <select name="task[schedule_weekday]" class="sw-select">
          <option value="">Choose a weekday</option>
          <%= for {label, value} <- @weekday_options do %>
            <option
              value={value}
              selected={
                to_string(Map.get(@task, :schedule_weekday) || Map.get(@task, "schedule_weekday", "")) ==
                  value
              }
            >
              {label}
            </option>
          <% end %>
        </select>
      </label>

      <label class="sw-field">
        <span>Timezone</span>
        <input
          name="task[timezone]"
          class="sw-input"
          value={Map.get(@task, :timezone) || Map.get(@task, "timezone", "Etc/UTC")}
        />
      </label>

      <label class="sw-field sw-field-span">
        <span>Target Room ID</span>
        <input
          name="task[room_id]"
          class="sw-input"
          value={Map.get(@task, :room_id) || Map.get(@task, "room_id", "")}
          placeholder="Optional for prompt tasks, required for room messages"
        />
      </label>

      <label class="sw-field sw-field-span">
        <span>Prompt Body</span>
        <textarea name="task[prompt_body]" class="sw-textarea" rows="8"><%= Map.get(@task, :prompt_body) || Map.get(@task, "prompt_body", "") %></textarea>
      </label>

      <label class="sw-field sw-field-span">
        <span>Message Body</span>
        <textarea name="task[message_body]" class="sw-textarea" rows="6"><%= Map.get(@task, :message_body) || Map.get(@task, "message_body", "") %></textarea>
      </label>

      <div class="sw-field-span sw-actions">
        <button type="submit" class="sw-btn sw-btn-primary">{@submit_label}</button>
      </div>
    </form>
    """
  end

  defp service_class(status) when is_binary(status) do
    cond do
      String.starts_with?(status, "ok") -> "is-ok"
      status == "skipped" -> "is-neutral"
      true -> "is-issue"
    end
  end

  defp request_message_preview(trace) do
    trace.request_payload
    |> case do
      %{"messages" => messages} when is_list(messages) ->
        messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{"role" => "user", "content" => content} when is_binary(content) -> content
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp truncate_text(text, max_length) when is_binary(text) do
    trimmed = String.trim(text)

    if String.length(trimmed) > max_length do
      String.slice(trimmed, 0, max_length - 1) <> "…"
    else
      trimmed
    end
  end

  defp normalize_llm_provider(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_), do: true

  defp pad_time(value) when is_integer(value),
    do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp pad_time(_), do: "00"

  defp weekday_label(1), do: "Monday"
  defp weekday_label("1"), do: "Monday"
  defp weekday_label(2), do: "Tuesday"
  defp weekday_label("2"), do: "Tuesday"
  defp weekday_label(3), do: "Wednesday"
  defp weekday_label("3"), do: "Wednesday"
  defp weekday_label(4), do: "Thursday"
  defp weekday_label("4"), do: "Thursday"
  defp weekday_label(5), do: "Friday"
  defp weekday_label("5"), do: "Friday"
  defp weekday_label(6), do: "Saturday"
  defp weekday_label("6"), do: "Saturday"
  defp weekday_label(7), do: "Sunday"
  defp weekday_label("7"), do: "Sunday"
  defp weekday_label(_), do: "Unknown"

  embed_templates "page_html/*"
end
