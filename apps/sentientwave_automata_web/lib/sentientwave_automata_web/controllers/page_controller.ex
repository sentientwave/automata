defmodule SentientwaveAutomataWeb.PageController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Matrix.Onboarding.Artifacts
  alias SentientwaveAutomata.Settings
  alias SentientwaveAutomata.System.Status
  alias SentientwaveAutomataWeb.AdminAuth

  @provider_options [
    {"Local (Fallback)", "local"},
    {"OpenAI", "openai"},
    {"Anthropic", "anthropic"},
    {"OpenRouter", "openrouter"},
    {"LM Studio", "lm-studio"},
    {"Ollama", "ollama"}
  ]
  @tool_options [
    {"Brave Internet Search", "brave_search"},
    {"System Directory Admin", "system_directory_admin"},
    {"Run Shell", "run_shell"}
  ]
  @skill_enabled_options [{"Any status", ""}, {"Enabled", "true"}, {"Disabled", "false"}]
  @trace_status_options [{"Any status", ""}, {"Successful", "ok"}, {"Errored", "error"}]
  @trace_call_kind_options [
    {"Any call type", ""},
    {"Response", "response"},
    {"Tool Planner", "tool_planner"},
    {"Tool Response", "tool_response"},
    {"Fallback Response", "response_fallback"}
  ]
  @trace_requester_kind_options [
    {"Any requester", ""},
    {"Human", "person"},
    {"Agent", "agent"},
    {"Unknown", "unknown"}
  ]
  @trace_scope_options [
    {"Any scope", ""},
    {"Room", "room"},
    {"Private Message", "private_message"},
    {"Unknown", "unknown"}
  ]

  def home(conn, _params), do: redirect(conn, to: ~p"/dashboard")

  def dashboard(conn, _params) do
    status = Status.summary()

    render(conn, :dashboard,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("dashboard")
    )
  end

  def onboarding(conn, params) do
    status = Status.summary()
    users_input = Map.get(params, "users", "")
    include_passwords = Map.get(params, "include_passwords", "false") in ["1", "true", "on"]

    artifacts =
      Artifacts.build(status, users_input: users_input, include_passwords: include_passwords)

    render(conn, :onboarding,
      status: status,
      artifacts: artifacts,
      admin_user: AdminAuth.expected_username(),
      nav: nav("onboarding")
    )
  end

  def llm(conn, _params) do
    render_llm(conn)
  end

  def new_llm_provider(conn, _params) do
    status = Status.summary()
    effective = Settings.llm_provider_effective()
    providers = Settings.list_llm_provider_configs()

    render(conn, :new_llm_provider,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("llm"),
      provider_options: @provider_options,
      llm: effective,
      providers: providers,
      token_configured?: token_configured?(effective.api_token),
      persisted?: effective.configured_in_db
    )
  end

  def llm_provider(conn, %{"id" => id}) do
    status = Status.summary()
    effective = Settings.llm_provider_effective()
    providers = Settings.list_llm_provider_configs()

    case Settings.get_llm_provider_config(id) do
      nil ->
        conn
        |> put_flash(:error, "Provider not found.")
        |> redirect(to: ~p"/settings/llm")

      provider ->
        render(conn, :llm_provider,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("llm"),
          provider_options: @provider_options,
          llm: effective,
          providers: providers,
          provider: provider,
          token_configured?: token_configured?(effective.api_token),
          persisted?: effective.configured_in_db
        )
    end
  end

  def tools(conn, _params) do
    render_tools(conn)
  end

  def skills(conn, params) do
    status = Status.summary()
    {skill_filters, skill_filter_form} = skill_filters_from_params(params)
    skills = Agents.list_skills(skill_filters)
    filtered_count = Agents.count_skills(skill_filters)
    total_count = Agents.count_skills()
    active_filters = active_skill_filters(skill_filters)

    render(conn, :skills,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("skills"),
      skills: skills,
      filtered_count: filtered_count,
      total_count: total_count,
      active_skill_count: Agents.count_skills(enabled: true),
      filter_form: skill_filter_form,
      active_filters: active_filters,
      skill_enabled_options: @skill_enabled_options
    )
  end

  def new_skill(conn, _params) do
    status = Status.summary()

    render(conn, :new_skill,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("skills")
    )
  end

  def skill(conn, %{"id" => id}) do
    status = Status.summary()

    case Agents.get_skill(id) do
      nil ->
        conn
        |> put_flash(:error, "Skill not found.")
        |> redirect(to: ~p"/settings/skills")

      skill ->
        designations = Agents.list_skill_designations(skill.id)
        assignable_agents = assignable_agents(skill, designations)

        render(conn, :skill,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("skills"),
          skill: skill,
          designations: designations,
          assignable_agents: assignable_agents
        )
    end
  end

  def new_tool(conn, _params) do
    status = Status.summary()
    tools = Settings.list_tool_configs()

    render(conn, :new_tool,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("tools"),
      tool_options: @tool_options,
      tools: tools
    )
  end

  def tool(conn, %{"id" => id}) do
    status = Status.summary()
    tools = Settings.list_tool_configs()

    case Settings.get_tool_config(id) do
      nil ->
        conn
        |> put_flash(:error, "Tool not found.")
        |> redirect(to: ~p"/settings/tools")

      tool ->
        render(conn, :tool,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("tools"),
          tool_options: @tool_options,
          tools: tools,
          tool: tool
        )
    end
  end

  def llm_traces(conn, params) do
    status = Status.summary()
    {trace_filters, trace_filter_form} = trace_filters_from_params(params)
    traces = Agents.list_llm_traces(filters: trace_filters, limit: 150)
    filtered_count = Agents.count_llm_traces(filters: trace_filters)
    total_count = Agents.count_llm_traces()
    active_filters = active_trace_filters(trace_filters)

    render(conn, :llm_traces,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("llm_traces"),
      traces: traces,
      filtered_count: filtered_count,
      total_count: total_count,
      error_count: Agents.count_llm_traces(filters: Map.put(trace_filters, :status, "error")),
      filter_form: trace_filter_form,
      active_filters: active_filters,
      provider_filter_options: provider_filter_options(),
      trace_status_options: @trace_status_options,
      trace_call_kind_options: @trace_call_kind_options,
      trace_requester_kind_options: @trace_requester_kind_options,
      trace_scope_options: @trace_scope_options
    )
  end

  def llm_trace(conn, %{"id" => id}) do
    status = Status.summary()

    case Agents.get_llm_trace(id) do
      nil ->
        conn
        |> put_flash(:error, "LLM trace not found.")
        |> redirect(to: ~p"/observability/llm-traces")

      trace ->
        render(conn, :llm_trace,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("llm_traces"),
          trace: trace
        )
    end
  end

  def create_llm_provider(conn, %{"llm" => llm_params}) do
    attrs = sanitize_llm_params(llm_params)
    clear_api_token = truthy?(Map.get(llm_params, "clear_api_token", "false"))

    case Settings.create_llm_provider_config(attrs,
           preserve_existing_token: false,
           clear_api_token: clear_api_token
         ) do
      {:ok, _config} ->
        conn
        |> put_flash(:info, "LLM provider added.")
        |> redirect(to: ~p"/settings/llm")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not add LLM provider.")
        |> redirect(to: ~p"/settings/llm")
    end
  end

  def create_llm_provider(conn, _params) do
    conn
    |> put_flash(:error, "Invalid provider payload.")
    |> redirect(to: ~p"/settings/llm")
  end

  def update_llm_provider(conn, %{"id" => id, "llm" => llm_params}) do
    attrs = sanitize_llm_params(llm_params)
    clear_api_token = truthy?(Map.get(llm_params, "clear_api_token", "false"))

    case Settings.get_llm_provider_config(id) do
      nil ->
        conn
        |> put_flash(:error, "Provider not found.")
        |> redirect(to: ~p"/settings/llm")

      config ->
        case Settings.update_llm_provider_config(config, attrs,
               preserve_existing_token: true,
               clear_api_token: clear_api_token
             ) do
          {:ok, _updated} ->
            conn
            |> put_flash(:info, "LLM provider updated.")
            |> redirect(to: ~p"/settings/llm/providers/#{config.id}")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Could not update LLM provider.")
            |> redirect(to: ~p"/settings/llm/providers/#{config.id}")
        end
    end
  end

  def update_llm_provider(conn, _params) do
    conn
    |> put_flash(:error, "Invalid provider update payload.")
    |> redirect(to: ~p"/settings/llm")
  end

  def set_default_llm_provider(conn, %{"id" => id}) do
    case Settings.set_default_llm_provider(id) do
      :ok ->
        conn
        |> put_flash(:info, "Default LLM provider updated.")
        |> redirect(to: ~p"/settings/llm")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not set default provider.")
        |> redirect(to: ~p"/settings/llm")
    end
  end

  def delete_llm_provider(conn, %{"id" => id}) do
    case Settings.delete_llm_provider(id) do
      :ok ->
        conn
        |> put_flash(:info, "LLM provider removed.")
        |> redirect(to: ~p"/settings/llm")

      {:error, :cannot_delete_last_provider} ->
        conn
        |> put_flash(:error, "At least one LLM provider must remain configured.")
        |> redirect(to: ~p"/settings/llm")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not remove provider.")
        |> redirect(to: ~p"/settings/llm")
    end
  end

  def create_tool(conn, %{"tool" => tool_params}) do
    attrs = sanitize_tool_params(tool_params)
    clear_api_token = truthy?(Map.get(tool_params, "clear_api_token", "false"))

    case Settings.create_tool_config(attrs,
           preserve_existing_token: false,
           clear_api_token: clear_api_token
         ) do
      {:ok, _config} ->
        conn
        |> put_flash(:info, "Tool added.")
        |> redirect(to: ~p"/settings/tools")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not add tool.")
        |> redirect(to: ~p"/settings/tools")
    end
  end

  def create_tool(conn, _params) do
    conn
    |> put_flash(:error, "Invalid tool payload.")
    |> redirect(to: ~p"/settings/tools")
  end

  def create_skill(conn, %{"skill" => skill_params}) do
    case Agents.create_skill(sanitize_skill_params(skill_params)) do
      {:ok, skill} ->
        conn
        |> put_flash(:info, "Skill created.")
        |> redirect(to: ~p"/settings/skills/#{skill.id}")

      {:error, changeset} ->
        conn
        |> put_flash(:error, skill_error_message(changeset, "Could not create skill."))
        |> redirect(to: ~p"/settings/skills/new")
    end
  end

  def create_skill(conn, _params) do
    conn
    |> put_flash(:error, "Invalid skill payload.")
    |> redirect(to: ~p"/settings/skills")
  end

  def update_skill(conn, %{"id" => id, "skill" => skill_params}) do
    case Agents.get_skill(id) do
      nil ->
        conn
        |> put_flash(:error, "Skill not found.")
        |> redirect(to: ~p"/settings/skills")

      skill ->
        case Agents.update_skill(skill, sanitize_skill_params(skill_params)) do
          {:ok, _skill} ->
            conn
            |> put_flash(:info, "Skill updated.")
            |> redirect(to: ~p"/settings/skills/#{id}")

          {:error, changeset} ->
            conn
            |> put_flash(:error, skill_error_message(changeset, "Could not update skill."))
            |> redirect(to: ~p"/settings/skills/#{id}")
        end
    end
  end

  def update_skill(conn, _params) do
    conn
    |> put_flash(:error, "Invalid skill update payload.")
    |> redirect(to: ~p"/settings/skills")
  end

  def designate_skill(conn, %{"id" => id, "designation" => %{"agent_id" => agent_id}}) do
    with %{} <- Agents.get_skill(id),
         true <- String.trim(agent_id) != "" do
      case Agents.designate_skill(id, String.trim(agent_id), %{
             metadata: %{"source" => "admin_ui"}
           }) do
        {:ok, _designation} ->
          conn
          |> put_flash(:info, "Skill designated to agent.")
          |> redirect(to: ~p"/settings/skills/#{id}")

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Could not designate skill.")
          |> redirect(to: ~p"/settings/skills/#{id}")
      end
    else
      nil ->
        conn
        |> put_flash(:error, "Skill not found.")
        |> redirect(to: ~p"/settings/skills")

      false ->
        conn
        |> put_flash(:error, "Choose an agent first.")
        |> redirect(to: ~p"/settings/skills/#{id}")
    end
  end

  def designate_skill(conn, %{"id" => id}) do
    conn
    |> put_flash(:error, "Choose an agent first.")
    |> redirect(to: ~p"/settings/skills/#{id}")
  end

  def rollback_skill_designation(conn, %{"id" => id, "designation_id" => designation_id}) do
    case Agents.rollback_skill_designation(designation_id, %{
           metadata: %{"rolled_back_from" => "admin_ui"}
         }) do
      {:ok, _designation} ->
        conn
        |> put_flash(:info, "Skill designation rolled back.")
        |> redirect(to: ~p"/settings/skills/#{id}")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not roll back skill designation.")
        |> redirect(to: ~p"/settings/skills/#{id}")
    end
  end

  def update_tool(conn, %{"id" => id, "tool" => tool_params}) do
    attrs = sanitize_tool_params(tool_params)
    clear_api_token = truthy?(Map.get(tool_params, "clear_api_token", "false"))

    case Settings.get_tool_config(id) do
      nil ->
        conn
        |> put_flash(:error, "Tool not found.")
        |> redirect(to: ~p"/settings/tools")

      config ->
        case Settings.update_tool_config(config, attrs,
               preserve_existing_token: true,
               clear_api_token: clear_api_token
             ) do
          {:ok, _updated} ->
            conn
            |> put_flash(:info, "Tool updated.")
            |> redirect(to: ~p"/settings/tools/#{config.id}")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Could not update tool.")
            |> redirect(to: ~p"/settings/tools/#{config.id}")
        end
    end
  end

  def update_tool(conn, _params) do
    conn
    |> put_flash(:error, "Invalid tool update payload.")
    |> redirect(to: ~p"/settings/tools")
  end

  def delete_tool(conn, %{"id" => id}) do
    case Settings.delete_tool_config(id) do
      :ok ->
        conn
        |> put_flash(:info, "Tool removed.")
        |> redirect(to: ~p"/settings/tools")

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not remove tool.")
        |> redirect(to: ~p"/settings/tools")
    end
  end

  defp render_llm(conn) do
    status = Status.summary()
    effective = Settings.llm_provider_effective()
    providers = Settings.list_llm_provider_configs()

    render(conn, :llm,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("llm"),
      provider_options: @provider_options,
      llm: effective,
      providers: providers,
      token_configured?: token_configured?(effective.api_token),
      persisted?: effective.configured_in_db
    )
  end

  defp render_tools(conn) do
    status = Status.summary()
    tools = Settings.list_tool_configs()

    render(conn, :tools,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("tools"),
      tool_options: @tool_options,
      tools: tools
    )
  end

  defp skill_filters_from_params(params) do
    raw = Map.get(params, "filters", %{})

    form_filters = %{
      "q" => fetch_skill_filter(raw, "q"),
      "enabled" => fetch_skill_filter(raw, "enabled")
    }

    query_filters =
      []
      |> maybe_put_skill_filter(:q, form_filters["q"])
      |> maybe_put_skill_enabled_filter(form_filters["enabled"])

    {query_filters, Phoenix.Component.to_form(form_filters, as: :filters)}
  end

  defp active_skill_filters(filters) do
    labels = %{
      q: "Search",
      enabled: "Status"
    }

    filters
    |> Enum.reduce([], fn {key, value}, acc ->
      if value in [nil, ""] do
        acc
      else
        rendered =
          case {key, value} do
            {:enabled, true} -> "Enabled"
            {:enabled, false} -> "Disabled"
            _ -> value
          end

        ["#{Map.get(labels, key, key)}: #{rendered}" | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp trace_filters_from_params(params) do
    raw = Map.get(params, "filters", %{})

    form_filters = %{
      "q" => fetch_trace_filter(raw, "q"),
      "provider" => fetch_trace_filter(raw, "provider"),
      "status" => fetch_trace_filter(raw, "status"),
      "call_kind" => fetch_trace_filter(raw, "call_kind"),
      "requester_kind" => fetch_trace_filter(raw, "requester_kind"),
      "conversation_scope" => fetch_trace_filter(raw, "conversation_scope")
    }

    query_filters =
      form_filters
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        case String.trim(value) do
          "" -> acc
          trimmed -> Map.put(acc, key, trimmed)
        end
      end)

    {query_filters, Phoenix.Component.to_form(form_filters, as: :filters)}
  end

  defp active_trace_filters(filters) do
    labels = %{
      "q" => "Search",
      "provider" => "Provider",
      "status" => "Status",
      "call_kind" => "Call Type",
      "requester_kind" => "Requester",
      "conversation_scope" => "Scope"
    }

    Enum.reduce(filters, [], fn {key, value}, acc ->
      if value in [nil, ""] do
        acc
      else
        ["#{Map.get(labels, key, key)}: #{value}" | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp provider_filter_options do
    [{"Any provider", ""} | @provider_options]
  end

  defp nav(active) do
    [
      %{id: "dashboard", label: "Dashboard", href: "/dashboard", active: active == "dashboard"},
      %{
        id: "onboarding",
        label: "Onboarding",
        href: "/onboarding",
        active: active == "onboarding"
      },
      %{id: "skills", label: "Skills", href: "/settings/skills", active: active == "skills"},
      %{id: "llm", label: "LLM Providers", href: "/settings/llm", active: active == "llm"},
      %{
        id: "llm_traces",
        label: "LLM Traces",
        href: "/observability/llm-traces",
        active: active == "llm_traces"
      },
      %{id: "tools", label: "Tools", href: "/settings/tools", active: active == "tools"}
    ]
  end

  defp sanitize_llm_params(params) do
    params
    |> Map.take([
      "name",
      "slug",
      "provider",
      "model",
      "base_url",
      "api_token",
      "enabled",
      "is_default",
      "timeout_seconds"
    ])
    |> Map.update("name", "Provider", &String.trim(to_string(&1)))
    |> Map.update("slug", "", &String.trim(to_string(&1)))
    |> Map.update("provider", "local", &normalize_provider/1)
    |> Map.update("model", "local-default", &String.trim(to_string(&1)))
    |> Map.update("base_url", "", &String.trim(to_string(&1)))
    |> Map.update("api_token", "", &String.trim(to_string(&1)))
    |> Map.update("enabled", true, &truthy?/1)
    |> Map.update("is_default", false, &truthy?/1)
    |> Map.update("timeout_seconds", 600, &normalize_timeout_seconds/1)
  end

  defp sanitize_tool_params(params) do
    params
    |> Map.take(["name", "slug", "tool_name", "base_url", "api_token", "enabled"])
    |> Map.update("name", "Brave Search", &String.trim(to_string(&1)))
    |> Map.update("slug", "", &String.trim(to_string(&1)))
    |> Map.update("tool_name", "brave_search", &normalize_tool_name/1)
    |> Map.update("base_url", "", &String.trim(to_string(&1)))
    |> Map.update("api_token", "", &String.trim(to_string(&1)))
    |> Map.update("enabled", true, &truthy?/1)
  end

  defp sanitize_skill_params(params) do
    summary = params |> Map.get("summary", "") |> to_string() |> String.trim()
    tags = params |> Map.get("tags", "") |> normalize_tags()

    %{
      "name" => params |> Map.get("name", "Skill") |> to_string() |> String.trim(),
      "slug" => params |> Map.get("slug", "") |> to_string() |> String.trim(),
      "markdown_body" => params |> Map.get("markdown_body", "") |> to_string() |> String.trim(),
      "enabled" => truthy?(Map.get(params, "enabled", "false")),
      "metadata" => %{
        "summary" => summary,
        "tags" => tags
      }
    }
  end

  defp normalize_provider(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_tool_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp truthy?(value) when value in [true, "true", "1", 1, "on"], do: true
  defp truthy?(_), do: false

  defp normalize_timeout_seconds(value) when is_integer(value), do: clamp_timeout_seconds(value)

  defp normalize_timeout_seconds(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, _} -> clamp_timeout_seconds(seconds)
      :error -> 600
    end
  end

  defp normalize_timeout_seconds(_), do: 600

  defp clamp_timeout_seconds(seconds) when seconds < 1, do: 1
  defp clamp_timeout_seconds(seconds) when seconds > 3600, do: 3600
  defp clamp_timeout_seconds(seconds), do: seconds

  defp token_configured?(token) when is_binary(token), do: String.trim(token) != ""
  defp token_configured?(_), do: false

  defp fetch_trace_filter(filters, key) do
    filters
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
  end

  defp fetch_skill_filter(filters, key) do
    filters
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
  end

  defp maybe_put_skill_filter(filters, _key, ""), do: filters
  defp maybe_put_skill_filter(filters, _key, nil), do: filters
  defp maybe_put_skill_filter(filters, key, value), do: Keyword.put(filters, key, value)

  defp maybe_put_skill_enabled_filter(filters, ""), do: filters
  defp maybe_put_skill_enabled_filter(filters, "true"), do: Keyword.put(filters, :enabled, true)
  defp maybe_put_skill_enabled_filter(filters, "false"), do: Keyword.put(filters, :enabled, false)
  defp maybe_put_skill_enabled_filter(filters, _), do: filters

  defp normalize_tags(value) do
    value
    |> to_string()
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp assignable_agents(_skill, designations) do
    assigned_agent_ids =
      designations
      |> Enum.filter(&(&1.status == :active))
      |> Enum.map(& &1.agent_id)
      |> MapSet.new()

    Agents.list_agents(kind: :agent, active_only: true)
    |> Enum.reject(&MapSet.member?(assigned_agent_ids, &1.id))
    |> Enum.sort_by(&{&1.display_name || "", &1.slug})
  end

  defp skill_error_message(changeset, fallback) do
    case changeset.errors do
      [{field, {message, _opts}} | _] ->
        "#{field} #{message}"

      _ ->
        fallback
    end
  end
end
