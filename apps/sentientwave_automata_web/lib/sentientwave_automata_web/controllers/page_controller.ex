defmodule SentientwaveAutomataWeb.PageController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.DirectoryManager
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.Onboarding.Artifacts
  alias SentientwaveAutomata.Settings
  alias SentientwaveAutomata.System.Status
  alias SentientwaveAutomataWeb.AdminAuth

  @directory_kind_filter_options [
    {"All types", ""},
    {"Human", "person"},
    {"Agent", "agent"},
    {"Service", "service"}
  ]
  @directory_kind_options [
    {"Human", "person"},
    {"Agent", "agent"},
    {"Service", "service"}
  ]
  @agent_status_options [{"Active", "active"}, {"Disabled", "disabled"}]
  @provider_options [
    {"Local (Fallback)", "local"},
    {"OpenAI", "openai"},
    {"Google Gemini", "gemini"},
    {"Anthropic", "anthropic"},
    {"Cerebras", "cerebras"},
    {"OpenRouter", "openrouter"},
    {"LM Studio", "lm-studio"},
    {"Ollama", "ollama"}
  ]
  @tool_options [
    {"Brave Internet Search", "brave_search"},
    {"System Directory Admin", "system_directory_admin"},
    {"Run Shell", "run_shell"}
  ]
  @scheduled_task_type_options [
    {"Run Agent Prompt", "run_agent_prompt"},
    {"Post Room Message", "post_room_message"}
  ]
  @scheduled_task_schedule_options [
    {"Hourly", "hourly"},
    {"Daily", "daily"},
    {"Weekly", "weekly"}
  ]
  @weekday_options [
    {"Monday", "1"},
    {"Tuesday", "2"},
    {"Wednesday", "3"},
    {"Thursday", "4"},
    {"Friday", "5"},
    {"Saturday", "6"},
    {"Sunday", "7"}
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
  @governance_law_status_options [
    {"Any status", ""},
    {"Active", "active"},
    {"Repealed", "repealed"}
  ]
  @governance_law_kind_options [
    {"Any kind", ""},
    {"General", "general"},
    {"Voting Policy", "voting_policy"}
  ]
  @governance_law_kind_choice_options [
    {"General", "general"},
    {"Voting Policy", "voting_policy"}
  ]
  @governance_role_status_options [
    {"Any status", ""},
    {"Enabled", "true"},
    {"Disabled", "false"}
  ]
  @governance_proposal_type_options [
    {"Create", "create"},
    {"Amend", "amend"},
    {"Repeal", "repeal"}
  ]
  @governance_proposal_status_options [
    {"Any status", ""},
    {"Open", "open"},
    {"Approved", "approved"},
    {"Rejected", "rejected"},
    {"Cancelled", "cancelled"}
  ]
  @governance_voting_scope_options [
    {"All members", "all_members"},
    {"Role subset", "role_subset"}
  ]
  @governance_approval_mode_options [
    {"Majority of cast votes", "majority"},
    {"Supermajority of cast votes", "supermajority"}
  ]
  @governance_vote_choice_options [
    {"Approve", "approve"},
    {"Reject", "reject"},
    {"Abstain", "abstain"}
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

  def directory(conn, params) do
    status = Status.summary()
    {directory_filters, directory_filter_form} = directory_filters_from_params(params)
    users = Directory.list_users(directory_filters)
    filtered_count = Directory.count_users(directory_filters)
    total_count = Directory.count_users()
    active_filters = active_directory_filters(directory_filters)

    render(conn, :directory,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("directory"),
      users: users,
      filtered_count: filtered_count,
      total_count: total_count,
      agent_count: Directory.count_users(kind: :agent),
      service_count: Directory.count_users(kind: :service),
      filter_form: directory_filter_form,
      active_filters: active_filters,
      directory_kind_filter_options: @directory_kind_filter_options
    )
  end

  def new_directory_user(conn, _params) do
    status = Status.summary()

    render(conn, :new_directory_user,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("directory"),
      directory_kind_options: @directory_kind_options,
      default_timezone: default_task_timezone()
    )
  end

  def directory_user(conn, %{"localpart" => localpart}) do
    status = Status.summary()

    case Directory.get_user(localpart) do
      nil ->
        conn
        |> put_flash(:error, "Directory user not found.")
        |> redirect(to: ~p"/directory/users")

      user ->
        agent_profile =
          if user.kind == :agent do
            Agents.ensure_agent_from_directory(user.localpart)
          end

        agent_wallet = agent_profile && Agents.get_agent_wallet(agent_profile.id)
        tool_rows = (agent_profile && agent_tool_rows(agent_profile)) || []
        scheduled_tasks = (agent_profile && Agents.list_scheduled_tasks(agent_profile.id)) || []

        render(conn, :directory_user,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("directory"),
          user: user,
          agent_profile: agent_profile,
          agent_wallet: agent_wallet,
          operational_status: DirectoryManager.operational_status(user),
          tool_rows: tool_rows,
          scheduled_tasks: scheduled_tasks,
          directory_kind_options: @directory_kind_options,
          agent_status_options: @agent_status_options
        )
    end
  end

  def new_directory_task(conn, %{"localpart" => localpart}) do
    status = Status.summary()

    with %{kind: :agent} = user <- Directory.get_user(localpart),
         %{} = agent_profile <- Agents.ensure_agent_from_directory(localpart) do
      render(conn, :new_directory_task,
        status: status,
        admin_user: AdminAuth.expected_username(),
        nav: nav("directory"),
        user: user,
        agent_profile: agent_profile,
        scheduled_task_type_options: @scheduled_task_type_options,
        scheduled_task_schedule_options: @scheduled_task_schedule_options,
        weekday_options: @weekday_options,
        default_timezone: default_task_timezone()
      )
    else
      _ ->
        conn
        |> put_flash(:error, "Only agent users can have scheduled tasks.")
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def constitution(conn, params) do
    status = Status.summary()
    {law_filters, law_filter_form} = governance_law_filters_from_params(params)
    laws = governance_list_laws(law_filters)
    proposals = governance_list_proposals(%{})
    roles = governance_list_roles(%{})
    snapshot = governance_current_constitution_snapshot()

    render(conn, :constitution,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("constitution"),
      laws: laws,
      proposals: proposals,
      roles: roles,
      snapshot: snapshot,
      filtered_law_count: length(laws),
      total_law_count: governance_total_law_count(),
      active_law_count: Enum.count(laws, &governance_law_active?/1),
      open_proposal_count: Enum.count(proposals, &governance_proposal_open?/1),
      role_count: length(roles),
      filter_form: law_filter_form,
      active_filters: active_governance_law_filters(law_filters),
      governance_law_status_options: @governance_law_status_options,
      governance_law_kind_options: @governance_law_kind_options,
      governance_available?: governance_available?()
    )
  end

  def constitution_law(conn, %{"id" => id}) do
    status = Status.summary()

    case governance_get_law(id) do
      nil ->
        conn
        |> put_flash(:error, "Law not found.")
        |> redirect(to: ~p"/constitution")

      law ->
        render(conn, :constitution_law,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("constitution"),
          law: law,
          proposals: governance_law_proposals(law),
          snapshots: governance_law_snapshots(law),
          current_snapshot: governance_current_constitution_snapshot(),
          governance_available?: governance_available?()
        )
    end
  end

  def constitution_proposal(conn, %{"id" => id}) do
    status = Status.summary()

    case governance_get_proposal(id) do
      nil ->
        conn
        |> put_flash(:error, "Proposal not found.")
        |> redirect(to: ~p"/constitution")

      proposal ->
        render(conn, :constitution_proposal,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("constitution"),
          proposal: proposal,
          votes: governance_proposal_votes(proposal),
          electorates: governance_proposal_electorates(proposal),
          role_choices: governance_proposal_roles(proposal),
          vote_tally: governance_vote_tally(proposal),
          proposal_status_options: @governance_proposal_status_options,
          governance_available?: governance_available?()
        )
    end
  end

  def new_constitution_proposal(conn, %{"proposal_type" => proposal_type} = params) do
    status = Status.summary()
    proposal_type = normalize_governance_proposal_type(proposal_type)
    linked_law = maybe_governance_get_law(Map.get(params, "law_id"))

    render(conn, :new_constitution_proposal,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("constitution"),
      proposal_type: proposal_type,
      proposal_type_label: governance_proposal_type_label(proposal_type),
      linked_law: linked_law,
      laws: governance_list_laws(%{}),
      roles: governance_list_roles(%{}),
      voting_scope_options: @governance_voting_scope_options,
      proposal_type_options: @governance_proposal_type_options,
      law_kind_options: @governance_law_kind_choice_options,
      approval_mode_options: @governance_approval_mode_options,
      vote_choice_options: @governance_vote_choice_options,
      governance_available?: governance_available?()
    )
  end

  def create_constitution_proposal(conn, %{"proposal" => proposal_params}) do
    attrs = sanitize_constitution_proposal_params(proposal_params)

    case governance_open_proposal(attrs) do
      {:ok, proposal} ->
        conn
        |> put_flash(:info, "Proposal created.")
        |> redirect(to: ~p"/constitution/proposals/#{proposal.id}")

      {:error, reason} ->
        conn
        |> put_flash(:error, governance_error_message(reason, "Could not create proposal."))
        |> redirect(
          to:
            ~p"/constitution/proposals/new/#{Map.get(proposal_params, "proposal_type", "create")}"
        )
    end
  end

  def create_constitution_proposal(conn, _params) do
    conn
    |> put_flash(:error, "Invalid proposal payload.")
    |> redirect(to: ~p"/constitution")
  end

  def constitution_roles(conn, params) do
    status = Status.summary()
    {role_filters, role_filter_form} = governance_role_filters_from_params(params)
    roles = governance_list_roles(role_filters)

    render(conn, :constitution_roles,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("constitution"),
      roles: roles,
      filtered_role_count: length(roles),
      total_role_count: governance_total_role_count(),
      active_role_count: Enum.count(roles, &governance_role_enabled?/1),
      filter_form: role_filter_form,
      active_filters: active_governance_role_filters(role_filters),
      role_enabled_options: @governance_role_status_options,
      governance_available?: governance_available?()
    )
  end

  def constitution_role(conn, %{"id" => id}) do
    status = Status.summary()
    users = Directory.list_users()

    case governance_get_role(id) do
      nil ->
        conn
        |> put_flash(:error, "Role not found.")
        |> redirect(to: ~p"/constitution/roles")

      role ->
        render(conn, :constitution_role,
          status: status,
          admin_user: AdminAuth.expected_username(),
          nav: nav("constitution"),
          role: role,
          assignments: governance_role_assignments(role),
          assignable_users: users,
          governance_available?: governance_available?()
        )
    end
  end

  def create_constitution_role(conn, %{"role" => role_params}) do
    attrs = sanitize_constitution_role_params(role_params)

    case governance_create_role(attrs) do
      {:ok, role} ->
        conn
        |> put_flash(:info, "Role created.")
        |> redirect(to: ~p"/constitution/roles/#{role.id}")

      {:error, reason} ->
        conn
        |> put_flash(:error, governance_error_message(reason, "Could not create role."))
        |> redirect(to: ~p"/constitution/roles")
    end
  end

  def create_constitution_role(conn, _params) do
    conn
    |> put_flash(:error, "Invalid role payload.")
    |> redirect(to: ~p"/constitution/roles")
  end

  def update_constitution_role(conn, %{"id" => id, "role" => role_params}) do
    attrs = sanitize_constitution_role_params(role_params)

    case governance_get_role(id) do
      nil ->
        conn
        |> put_flash(:error, "Role not found.")
        |> redirect(to: ~p"/constitution/roles")

      role ->
        case governance_update_role(role, attrs) do
          {:ok, updated_role} ->
            conn
            |> put_flash(:info, "Role updated.")
            |> redirect(to: ~p"/constitution/roles/#{updated_role.id}")

          {:error, reason} ->
            conn
            |> put_flash(:error, governance_error_message(reason, "Could not update role."))
            |> redirect(to: ~p"/constitution/roles/#{id}")
        end
    end
  end

  def update_constitution_role(conn, %{"id" => id}) do
    conn
    |> put_flash(:error, "Invalid role payload.")
    |> redirect(to: ~p"/constitution/roles/#{id}")
  end

  def assign_constitution_role(conn, %{"id" => id, "role_assignment" => assignment_params}) do
    attrs = sanitize_constitution_role_assignment_params(assignment_params)

    case governance_assign_role(id, attrs) do
      {:ok, _assignment} ->
        conn
        |> put_flash(:info, "Role assigned.")
        |> redirect(to: ~p"/constitution/roles/#{id}")

      {:error, reason} ->
        conn
        |> put_flash(:error, governance_error_message(reason, "Could not assign role."))
        |> redirect(to: ~p"/constitution/roles/#{id}")
    end
  end

  def assign_constitution_role(conn, %{"id" => id}) do
    conn
    |> put_flash(:error, "Choose a directory user first.")
    |> redirect(to: ~p"/constitution/roles/#{id}")
  end

  def revoke_constitution_role_assignment(
        conn,
        %{"id" => id, "assignment_id" => assignment_id}
      ) do
    case governance_revoke_role_assignment(id, assignment_id) do
      {:ok, _assignment} ->
        conn
        |> put_flash(:info, "Role assignment revoked.")
        |> redirect(to: ~p"/constitution/roles/#{id}")

      {:error, reason} ->
        conn
        |> put_flash(:error, governance_error_message(reason, "Could not revoke assignment."))
        |> redirect(to: ~p"/constitution/roles/#{id}")
    end
  end

  def directory_task(conn, %{"localpart" => localpart, "id" => id}) do
    status = Status.summary()

    with %{kind: :agent} = user <- Directory.get_user(localpart),
         %{} = task <- Agents.get_scheduled_task(id),
         true <- task.agent && task.agent.matrix_localpart == user.localpart do
      render(conn, :directory_task,
        status: status,
        admin_user: AdminAuth.expected_username(),
        nav: nav("directory"),
        user: user,
        task: task,
        scheduled_task_type_options: @scheduled_task_type_options,
        scheduled_task_schedule_options: @scheduled_task_schedule_options,
        weekday_options: @weekday_options
      )
    else
      _ ->
        conn
        |> put_flash(:error, "Scheduled task not found.")
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def llm(conn, _params) do
    render_llm(conn)
  end

  def new_llm_provider(conn, params) do
    status = Status.summary()
    effective = Settings.llm_provider_effective()
    providers = Settings.list_llm_provider_configs()
    selected_provider = normalize_provider(Map.get(params, "provider", "local"))

    render(conn, :new_llm_provider,
      status: status,
      admin_user: AdminAuth.expected_username(),
      nav: nav("llm"),
      provider_options: @provider_options,
      selected_provider: selected_provider,
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
        |> put_flash(:error, "Trace not found.")
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
        |> put_flash(:info, "Provider added.")
        |> redirect(to: ~p"/settings/llm")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not add provider.")
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
            |> put_flash(:info, "Provider updated.")
            |> redirect(to: ~p"/settings/llm/providers/#{config.id}")

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Could not update provider.")
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
        |> put_flash(:info, "Default provider updated.")
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
        |> put_flash(:info, "Provider removed.")
        |> redirect(to: ~p"/settings/llm")

      {:error, :cannot_delete_last_provider} ->
        conn
        |> put_flash(:error, "At least one provider must remain configured.")
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

  def create_directory_user(conn, %{"user" => user_params}) do
    case DirectoryManager.create_user(sanitize_directory_user_params(user_params)) do
      {:ok, result} ->
        conn
        |> put_flash(:info, generated_password_message(result))
        |> put_warning_flash(result.warnings)
        |> redirect(to: ~p"/directory/users/#{result.user.localpart}")

      {:error, errors} ->
        conn
        |> put_flash(:error, directory_error_message(errors, "Could not create directory user."))
        |> redirect(to: ~p"/directory/users/new")
    end
  end

  def create_directory_user(conn, _params) do
    conn
    |> put_flash(:error, "Invalid directory user payload.")
    |> redirect(to: ~p"/directory/users")
  end

  def update_directory_user(conn, %{"localpart" => localpart, "user" => user_params}) do
    case DirectoryManager.update_user(localpart, sanitize_directory_user_params(user_params)) do
      {:ok, result} ->
        conn
        |> put_flash(:info, "Directory user updated.")
        |> put_warning_flash(result.warnings)
        |> redirect(to: ~p"/directory/users/#{result.user.localpart}")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Directory user not found.")
        |> redirect(to: ~p"/directory/users")

      {:error, errors} ->
        conn
        |> put_flash(:error, directory_error_message(errors, "Could not update directory user."))
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def update_directory_user(conn, %{"localpart" => localpart}) do
    conn
    |> put_flash(:error, "Invalid directory user payload.")
    |> redirect(to: ~p"/directory/users/#{localpart}")
  end

  def rotate_directory_user_password(conn, %{"localpart" => localpart}) do
    case DirectoryManager.rotate_password(localpart) do
      {:ok, result} ->
        conn
        |> put_flash(:info, generated_password_message(result))
        |> put_warning_flash(result.warnings)
        |> redirect(to: ~p"/directory/users/#{result.user.localpart}")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Directory user not found.")
        |> redirect(to: ~p"/directory/users")

      {:error, reason} ->
        conn
        |> put_flash(:error, directory_error_message(reason, "Could not rotate credentials."))
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def delete_directory_user(conn, %{"localpart" => localpart}) do
    case DirectoryManager.deactivate_user(localpart) do
      {:ok, warnings} ->
        conn
        |> put_flash(:info, "Directory user deactivated.")
        |> put_warning_flash(warnings)
        |> redirect(to: ~p"/directory/users")

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Directory user not found.")
        |> redirect(to: ~p"/directory/users")

      {:error, reason} ->
        conn
        |> put_flash(
          :error,
          directory_error_message(reason, "Could not deactivate directory user.")
        )
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def update_directory_agent_profile(
        conn,
        %{"localpart" => localpart, "agent_profile" => profile_params}
      ) do
    with %{kind: :agent} = user <- Directory.get_user(localpart),
         %{} = current_profile <- Agents.ensure_agent_from_directory(localpart),
         {:ok, metadata} <- parse_metadata_json(Map.get(profile_params, "metadata", "{}")),
         {:ok, user_result} <- maybe_sync_agent_directory_identity(user, profile_params),
         target_localpart = user_result.user.localpart,
         profile_attrs =
           sanitize_agent_profile_params(
             profile_params,
             current_profile,
             target_localpart,
             metadata
           ),
         {:ok, _profile} <- Agents.upsert_agent(profile_attrs) do
      conn
      |> put_flash(:info, "Agent runtime settings updated.")
      |> put_warning_flash(user_result.warnings)
      |> redirect(to: ~p"/directory/users/#{target_localpart}")
    else
      nil ->
        conn
        |> put_flash(:error, "Agent user not found.")
        |> redirect(to: ~p"/directory/users")

      {:error, :invalid_metadata} ->
        conn
        |> put_flash(:error, "Agent metadata must be valid JSON.")
        |> redirect(to: ~p"/directory/users/#{localpart}")

      {:error, errors} ->
        conn
        |> put_flash(
          :error,
          directory_error_message(errors, "Could not update agent runtime settings.")
        )
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def update_directory_agent_profile(conn, %{"localpart" => localpart}) do
    conn
    |> put_flash(:error, "Invalid agent runtime payload.")
    |> redirect(to: ~p"/directory/users/#{localpart}")
  end

  def update_directory_tool_permission(
        conn,
        %{"localpart" => localpart, "tool_permission" => permission_params}
      ) do
    with %{kind: :agent} <- Directory.get_user(localpart),
         %{} = agent <- Agents.ensure_agent_from_directory(localpart),
         tool_name when is_binary(tool_name) and tool_name != "" <-
           permission_params |> Map.get("tool_name", "") |> String.trim(),
         action when action in ["allow", "block", "default"] <-
           permission_params |> Map.get("action", "") |> String.trim(),
         :ok <- persist_tool_override(agent, tool_name, action) do
      conn
      |> put_flash(:info, "Tool access updated.")
      |> redirect(to: ~p"/directory/users/#{localpart}")
    else
      _ ->
        conn
        |> put_flash(:error, "Could not update tool access.")
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def create_directory_task(conn, %{"localpart" => localpart, "task" => task_params}) do
    with %{kind: :agent} <- Directory.get_user(localpart),
         %{} = agent <- Agents.ensure_agent_from_directory(localpart),
         {:ok, _task} <- Agents.create_scheduled_task(agent.id, sanitize_task_params(task_params)) do
      conn
      |> put_flash(:info, "Scheduled task created.")
      |> redirect(to: ~p"/directory/users/#{localpart}")
    else
      {:error, changeset} ->
        conn
        |> put_flash(
          :error,
          directory_error_message(changeset, "Could not create scheduled task.")
        )
        |> redirect(to: ~p"/directory/users/#{localpart}/tasks/new")

      _ ->
        conn
        |> put_flash(:error, "Only agent users can have scheduled tasks.")
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def update_directory_task(conn, %{"localpart" => localpart, "id" => id, "task" => task_params}) do
    case Agents.get_scheduled_task(id) do
      %{agent: %{matrix_localpart: ^localpart}} = task ->
        case Agents.update_scheduled_task(task, sanitize_task_params(task_params)) do
          {:ok, _task} ->
            conn
            |> put_flash(:info, "Scheduled task updated.")
            |> redirect(to: ~p"/directory/users/#{localpart}/tasks/#{id}")

          {:error, changeset} ->
            conn
            |> put_flash(
              :error,
              directory_error_message(changeset, "Could not update scheduled task.")
            )
            |> redirect(to: ~p"/directory/users/#{localpart}/tasks/#{id}")
        end

      _ ->
        conn
        |> put_flash(:error, "Scheduled task not found.")
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def toggle_directory_task(conn, %{"localpart" => localpart, "id" => id, "enabled" => enabled}) do
    case Agents.get_scheduled_task(id) do
      %{agent: %{matrix_localpart: ^localpart}} = task ->
        case Agents.set_scheduled_task_enabled(task, truthy?(enabled)) do
          {:ok, _task} ->
            conn
            |> put_flash(:info, "Scheduled task state updated.")
            |> redirect(to: ~p"/directory/users/#{localpart}")

          {:error, changeset} ->
            conn
            |> put_flash(
              :error,
              directory_error_message(changeset, "Could not update scheduled task state.")
            )
            |> redirect(to: ~p"/directory/users/#{localpart}")
        end

      _ ->
        conn
        |> put_flash(:error, "Scheduled task not found.")
        |> redirect(to: ~p"/directory/users/#{localpart}")
    end
  end

  def delete_directory_task(conn, %{"localpart" => localpart, "id" => id}) do
    case Agents.get_scheduled_task(id) do
      %{agent: %{matrix_localpart: ^localpart}} = task ->
        case Agents.delete_scheduled_task(task) do
          :ok ->
            conn
            |> put_flash(:info, "Scheduled task removed.")
            |> redirect(to: ~p"/directory/users/#{localpart}")

          {:error, reason} ->
            conn
            |> put_flash(
              :error,
              directory_error_message(reason, "Could not remove scheduled task.")
            )
            |> redirect(to: ~p"/directory/users/#{localpart}")
        end

      _ ->
        conn
        |> put_flash(:error, "Scheduled task not found.")
        |> redirect(to: ~p"/directory/users/#{localpart}")
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

  defp directory_filters_from_params(params) do
    raw = Map.get(params, "filters", %{})

    form_filters = %{
      "q" => fetch_directory_filter(raw, "q"),
      "kind" => fetch_directory_filter(raw, "kind")
    }

    query_filters =
      []
      |> maybe_put_directory_filter(:q, form_filters["q"])
      |> maybe_put_directory_kind_filter(form_filters["kind"])

    {query_filters, Phoenix.Component.to_form(form_filters, as: :filters)}
  end

  defp active_directory_filters(filters) do
    labels = %{
      q: "Search",
      kind: "Type"
    }

    filters
    |> Enum.reduce([], fn {key, value}, acc ->
      if value in [nil, ""] do
        acc
      else
        rendered =
          case {key, value} do
            {:kind, :person} -> "Human"
            {:kind, :agent} -> "Agent"
            {:kind, :service} -> "Service"
            _ -> value
          end

        ["#{Map.get(labels, key, key)}: #{rendered}" | acc]
      end
    end)
    |> Enum.reverse()
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
      %{
        id: "directory",
        label: "Directory",
        href: "/directory/users",
        active: active == "directory"
      },
      %{
        id: "constitution",
        label: "Constitution",
        href: "/constitution",
        active: active == "constitution"
      },
      %{id: "skills", label: "Skills", href: "/settings/skills", active: active == "skills"},
      %{id: "llm", label: "Providers", href: "/settings/llm", active: active == "llm"},
      %{
        id: "llm_traces",
        label: "Traces",
        href: "/observability/llm-traces",
        active: active == "llm_traces"
      },
      %{id: "tools", label: "Tools", href: "/settings/tools", active: active == "tools"}
    ]
  end

  defp sanitize_llm_params(params) do
    provider =
      params
      |> Map.get("provider", "local")
      |> normalize_provider()

    defaults = Settings.llm_provider_defaults(provider)

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
    |> Map.put("provider", provider)
    |> Map.update("model", defaults.model, &default_provider_field(&1, defaults.model))
    |> Map.update("base_url", defaults.base_url, &default_provider_field(&1, defaults.base_url))
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

  defp sanitize_directory_user_params(params) do
    %{
      "localpart" => params |> Map.get("localpart", "") |> to_string() |> String.trim(),
      "kind" => params |> Map.get("kind", "person") |> to_string() |> String.trim(),
      "display_name" => params |> Map.get("display_name", "") |> to_string() |> String.trim(),
      "admin" => truthy?(Map.get(params, "admin", "false"))
    }
  end

  defp sanitize_agent_profile_params(params, current_profile, matrix_localpart, metadata) do
    slug =
      params
      |> Map.get("slug", current_profile.slug || matrix_localpart)
      |> to_string()
      |> String.trim()

    %{
      slug: if(slug == "", do: matrix_localpart, else: slug),
      kind: :agent,
      display_name:
        params
        |> Map.get("display_name", current_profile.display_name || "Agent #{matrix_localpart}")
        |> to_string()
        |> String.trim(),
      matrix_localpart: matrix_localpart,
      status:
        case params |> Map.get("status", current_profile.status |> to_string()) |> to_string() do
          "disabled" -> :disabled
          _ -> :active
        end,
      metadata: metadata
    }
  end

  defp sanitize_task_params(params) do
    %{
      "name" => params |> Map.get("name", "") |> to_string() |> String.trim(),
      "enabled" => truthy?(Map.get(params, "enabled", "false")),
      "task_type" =>
        params |> Map.get("task_type", "run_agent_prompt") |> to_string() |> String.trim(),
      "schedule_type" =>
        params |> Map.get("schedule_type", "daily") |> to_string() |> String.trim(),
      "schedule_interval" =>
        params |> Map.get("schedule_interval", "1") |> to_string() |> String.trim(),
      "schedule_hour" => params |> Map.get("schedule_hour", "") |> to_string() |> String.trim(),
      "schedule_minute" =>
        params |> Map.get("schedule_minute", "0") |> to_string() |> String.trim(),
      "schedule_weekday" =>
        params |> Map.get("schedule_weekday", "") |> to_string() |> String.trim(),
      "timezone" =>
        params |> Map.get("timezone", default_task_timezone()) |> to_string() |> String.trim(),
      "room_id" => params |> Map.get("room_id", "") |> to_string() |> String.trim(),
      "prompt_body" => params |> Map.get("prompt_body", "") |> to_string() |> String.trim(),
      "message_body" => params |> Map.get("message_body", "") |> to_string() |> String.trim(),
      "metadata" => %{"source" => "admin_ui"}
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

  defp default_provider_field(value, fallback) do
    case value |> to_string() |> String.trim() do
      "" -> fallback
      trimmed -> trimmed
    end
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
  defp maybe_put_directory_filter(filters, _key, ""), do: filters
  defp maybe_put_directory_filter(filters, _key, nil), do: filters
  defp maybe_put_directory_filter(filters, key, value), do: Keyword.put(filters, key, value)

  defp maybe_put_skill_enabled_filter(filters, ""), do: filters
  defp maybe_put_skill_enabled_filter(filters, "true"), do: Keyword.put(filters, :enabled, true)
  defp maybe_put_skill_enabled_filter(filters, "false"), do: Keyword.put(filters, :enabled, false)
  defp maybe_put_skill_enabled_filter(filters, _), do: filters

  defp maybe_put_directory_kind_filter(filters, ""), do: filters

  defp maybe_put_directory_kind_filter(filters, "person"),
    do: Keyword.put(filters, :kind, :person)

  defp maybe_put_directory_kind_filter(filters, "human"), do: Keyword.put(filters, :kind, :person)
  defp maybe_put_directory_kind_filter(filters, "agent"), do: Keyword.put(filters, :kind, :agent)

  defp maybe_put_directory_kind_filter(filters, "service"),
    do: Keyword.put(filters, :kind, :service)

  defp maybe_put_directory_kind_filter(filters, _), do: filters

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

  defp directory_error_message(%Ecto.Changeset{} = changeset, fallback),
    do: skill_error_message(changeset, fallback)

  defp directory_error_message(%{} = errors, fallback) do
    case Enum.at(Map.to_list(errors), 0) do
      {field, message} -> "#{field} #{message}"
      _ -> fallback
    end
  end

  defp directory_error_message(reason, _fallback) when is_binary(reason), do: reason
  defp directory_error_message(_reason, fallback), do: fallback

  defp generated_password_message(result) do
    password = Map.get(result, :generated_password)
    localpart = result.user.localpart

    if is_binary(password) and password != "" do
      "Generated password for #{localpart}: #{password}"
    else
      "Credentials updated."
    end
  end

  defp put_warning_flash(conn, []), do: conn

  defp put_warning_flash(conn, warnings) when is_list(warnings) do
    warnings =
      warnings
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.reverse()

    if warnings == [] do
      conn
    else
      put_flash(conn, :error, Enum.join(warnings, " "))
    end
  end

  defp maybe_sync_agent_directory_identity(user, profile_params) do
    target_localpart =
      profile_params
      |> Map.get("matrix_localpart", user.localpart)
      |> to_string()
      |> String.trim()

    display_name =
      profile_params
      |> Map.get("display_name", user.display_name)
      |> to_string()
      |> String.trim()

    if target_localpart != "" and target_localpart != user.localpart do
      DirectoryManager.update_user(user.localpart, %{
        localpart: target_localpart,
        kind: "agent",
        display_name: display_name
      })
    else
      {:ok, %{user: user, generated_password: nil, warnings: []}}
    end
  end

  defp persist_tool_override(agent, tool_name, "allow") do
    Agents.set_tool_permission(%{
      agent_id: agent.id,
      tool_name: tool_name,
      scope: "default",
      allowed: true,
      constraints: %{"source" => "admin_ui"}
    })
    |> case do
      {:ok, _permission} -> :ok
      {:error, _reason} -> {:error, :persist_failed}
    end
  end

  defp persist_tool_override(agent, tool_name, "block") do
    Agents.set_tool_permission(%{
      agent_id: agent.id,
      tool_name: tool_name,
      scope: "default",
      allowed: false,
      constraints: %{"source" => "admin_ui"}
    })
    |> case do
      {:ok, _permission} -> :ok
      {:error, _reason} -> {:error, :persist_failed}
    end
  end

  defp persist_tool_override(agent, tool_name, "default") do
    :ok = Agents.reset_tool_permission(agent.id, tool_name, "default")
    :ok
  end

  defp agent_tool_rows(agent) do
    permissions =
      Agents.list_tool_permissions_for_agent(agent.id)
      |> Map.new(fn permission -> {permission.tool_name, permission} end)

    Settings.list_enabled_tool_configs()
    |> Enum.map(fn config ->
      permission = Map.get(permissions, config.tool_name)
      privileged = config.tool_name in ["system_directory_admin", "run_shell"]

      {effective_allowed, source_label} =
        case permission do
          %{allowed: true} -> {true, "Explicit Allow"}
          %{allowed: false} -> {false, "Explicit Block"}
          nil when privileged -> {false, "Default Block"}
          nil -> {true, "Default Allow"}
        end

      %{
        id: config.id,
        tool_name: config.tool_name,
        label: config.name,
        effective_allowed: effective_allowed,
        source_label: source_label
      }
    end)
    |> Enum.sort_by(&{&1.label, &1.tool_name})
  end

  defp governance_available? do
    Code.ensure_loaded?(SentientwaveAutomata.Governance) and
      function_exported?(SentientwaveAutomata.Governance, :list_laws, 1)
  end

  defp maybe_governance_get_law(nil), do: nil
  defp maybe_governance_get_law(id) when is_binary(id) and id != "", do: governance_get_law(id)
  defp maybe_governance_get_law(_), do: nil

  defp governance_proposal_type_label(:create), do: "Create Proposal"
  defp governance_proposal_type_label(:amend), do: "Amend Proposal"
  defp governance_proposal_type_label(:repeal), do: "Repeal Proposal"
  defp governance_proposal_type_label("create"), do: "Create Proposal"
  defp governance_proposal_type_label("amend"), do: "Amend Proposal"
  defp governance_proposal_type_label("repeal"), do: "Repeal Proposal"
  defp governance_proposal_type_label(_), do: "Create Proposal"

  defp governance_role_assignments(role) when is_map(role) do
    role
    |> Map.get(:assignments, Map.get(role, "assignments", []))
    |> List.wrap()
  end

  defp governance_role_assignments(_), do: []

  defp governance_error_message(%Ecto.Changeset{} = changeset, fallback),
    do: skill_error_message(changeset, fallback)

  defp governance_error_message(%{} = errors, fallback) do
    case Enum.at(Map.to_list(errors), 0) do
      {field, message} -> "#{field} #{message}"
      _ -> fallback
    end
  end

  defp governance_error_message(reason, _fallback) when is_binary(reason), do: reason
  defp governance_error_message(_reason, fallback), do: fallback

  defp governance_total_law_count, do: governance_list_laws(%{}) |> length()
  defp governance_total_role_count, do: governance_list_roles(%{}) |> length()

  defp governance_list_laws(filters) when is_list(filters) or is_map(filters),
    do: governance_call(:list_laws, [filters], [])

  defp governance_list_roles(filters) when is_list(filters) or is_map(filters),
    do: governance_call(:list_roles, [filters], [])

  defp governance_list_proposals(filters) when is_list(filters) or is_map(filters),
    do: governance_call(:list_proposals, [filters], [])

  defp governance_get_law(id) when is_binary(id) and id != "",
    do: governance_call(:get_law, [id], nil)

  defp governance_get_law(_), do: nil

  defp governance_get_proposal(id) when is_binary(id) and id != "",
    do: governance_call(:get_proposal, [id], nil)

  defp governance_get_proposal(_), do: nil

  defp governance_get_role(id) when is_binary(id) and id != "",
    do: governance_call(:get_role, [id], nil)

  defp governance_get_role(_), do: nil

  defp governance_open_proposal(attrs) when is_map(attrs),
    do: governance_call(:open_law_proposal, [attrs], {:error, :unavailable})

  defp governance_create_role(attrs) when is_map(attrs),
    do: governance_call(:create_role, [attrs], {:error, :unavailable})

  defp governance_update_role(role, attrs) when is_map(attrs),
    do: governance_call(:update_role, [role, attrs], {:error, :unavailable})

  defp governance_assign_role(role_id, attrs) when is_map(attrs),
    do: governance_call(:assign_role, [role_id, attrs], {:error, :unavailable})

  defp governance_revoke_role_assignment(role_id, assignment_id),
    do: governance_call(:revoke_role_assignment, [role_id, assignment_id], {:error, :unavailable})

  defp governance_current_constitution_snapshot do
    governance_call(:current_constitution_snapshot, [], nil)
  end

  defp governance_law_proposals(law) when is_map(law) do
    Map.get(law, :proposals, Map.get(law, "proposals", []))
    |> List.wrap()
  end

  defp governance_law_snapshots(law) when is_map(law) do
    Map.get(
      law,
      :snapshots,
      Map.get(law, "snapshots", Map.get(law, :constitution_snapshots, []))
    )
    |> List.wrap()
  end

  defp governance_proposal_votes(proposal) when is_map(proposal) do
    proposal
    |> Map.get(:votes, Map.get(proposal, "votes", []))
    |> List.wrap()
    |> Enum.map(fn vote ->
      voter = Map.get(vote, :voter, Map.get(vote, "voter", %{}))

      Map.merge(
        %{
          voter_mxid: governance_member_mxid(voter)
        },
        governance_value_to_map(vote)
      )
    end)
  end

  defp governance_proposal_electorates(proposal) when is_map(proposal) do
    proposal
    |> Map.get(:electorates, Map.get(proposal, "electorates", Map.get(proposal, :electors, [])))
    |> List.wrap()
    |> Enum.map(fn elector ->
      user = Map.get(elector, :user, Map.get(elector, "user", %{}))

      %{
        id: Map.get(user, :id, Map.get(user, "id")),
        display_name: Map.get(user, :display_name, Map.get(user, "display_name")),
        localpart: Map.get(user, :localpart, Map.get(user, "localpart")),
        kind: Map.get(user, :kind, Map.get(user, "kind")),
        mxid: governance_member_mxid(user),
        eligibility_reason:
          Map.get(elector, :eligible_via, Map.get(elector, "eligible_via", "Eligible"))
      }
    end)
  end

  defp governance_proposal_roles(proposal) when is_map(proposal) do
    proposal
    |> Map.get(
      :eligible_roles,
      Map.get(proposal, "eligible_roles", Map.get(proposal, :eligible_role_links, []))
    )
    |> List.wrap()
    |> Enum.map(fn role_or_link ->
      Map.get(role_or_link, :role, Map.get(role_or_link, "role", role_or_link))
    end)
  end

  defp governance_vote_tally(%{} = proposal) do
    case Map.get(proposal, :vote_tally, Map.get(proposal, "vote_tally")) do
      %{} = tally ->
        normalize_vote_tally(tally)

      _ ->
        votes = governance_proposal_votes(proposal)
        tally_from_votes(votes)
    end
  end

  defp normalize_vote_tally(tally) when is_map(tally) do
    %{
      approve: Map.get(tally, :approve, Map.get(tally, "approve", 0)),
      reject: Map.get(tally, :reject, Map.get(tally, "reject", 0)),
      abstain: Map.get(tally, :abstain, Map.get(tally, "abstain", 0))
    }
  end

  defp tally_from_votes(votes) do
    Enum.reduce(votes, %{approve: 0, reject: 0, abstain: 0}, fn vote, acc ->
      case Map.get(vote, :choice, Map.get(vote, "choice")) do
        :approve -> Map.update!(acc, :approve, &(&1 + 1))
        "approve" -> Map.update!(acc, :approve, &(&1 + 1))
        :reject -> Map.update!(acc, :reject, &(&1 + 1))
        "reject" -> Map.update!(acc, :reject, &(&1 + 1))
        :abstain -> Map.update!(acc, :abstain, &(&1 + 1))
        "abstain" -> Map.update!(acc, :abstain, &(&1 + 1))
        _ -> acc
      end
    end)
  end

  defp governance_law_active?(law) when is_map(law) do
    Map.get(law, :status, Map.get(law, "status")) in [:active, "active"]
  end

  defp governance_proposal_open?(proposal) when is_map(proposal) do
    Map.get(proposal, :status, Map.get(proposal, "status")) in [:open, "open"]
  end

  defp governance_role_enabled?(role) when is_map(role) do
    Map.get(role, :enabled, Map.get(role, "enabled", true)) in [true, "true", :active, "active"]
  end

  defp governance_call(fun, args, fallback) do
    module = SentientwaveAutomata.Governance

    if Code.ensure_loaded?(module) and function_exported?(module, fun, length(args)) do
      apply(module, fun, args)
    else
      fallback
    end
  end

  defp governance_member_mxid(member) when is_map(member) do
    localpart = Map.get(member, :localpart, Map.get(member, "localpart", ""))
    domain = System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")

    case to_string(localpart) |> String.trim() do
      "" -> "n/a"
      normalized -> "@#{normalized}:#{domain}"
    end
  end

  defp governance_value_to_map(%_{} = value), do: Map.from_struct(value)
  defp governance_value_to_map(value) when is_map(value), do: value
  defp governance_value_to_map(_value), do: %{}

  defp governance_law_filters_from_params(params) do
    raw = Map.get(params, "filters", %{})

    form_filters = %{
      "q" => fetch_governance_filter(raw, "q"),
      "status" => fetch_governance_filter(raw, "status"),
      "law_kind" => fetch_governance_filter(raw, "law_kind")
    }

    query_filters =
      []
      |> maybe_put_governance_filter(:q, form_filters["q"])
      |> maybe_put_governance_filter(
        :status,
        normalize_governance_status_filter(form_filters["status"])
      )
      |> maybe_put_governance_filter(
        :law_kind,
        normalize_governance_kind_filter(form_filters["law_kind"])
      )

    {query_filters, Phoenix.Component.to_form(form_filters, as: :filters)}
  end

  defp governance_role_filters_from_params(params) do
    raw = Map.get(params, "filters", %{})

    form_filters = %{
      "q" => fetch_governance_filter(raw, "q"),
      "enabled" => fetch_governance_filter(raw, "enabled")
    }

    query_filters =
      []
      |> maybe_put_governance_filter(:q, form_filters["q"])
      |> maybe_put_governance_filter(
        :enabled,
        normalize_governance_enabled_filter(form_filters["enabled"])
      )

    {query_filters, Phoenix.Component.to_form(form_filters, as: :filters)}
  end

  defp active_governance_law_filters(filters) do
    labels = %{q: "Search", status: "Status", law_kind: "Law Kind"}

    filters
    |> Enum.reduce([], fn {key, value}, acc ->
      if value in [nil, ""] do
        acc
      else
        rendered =
          case {key, value} do
            {:status, :active} -> "Active"
            {:status, :repealed} -> "Repealed"
            {:law_kind, :general} -> "General"
            {:law_kind, :voting_policy} -> "Voting Policy"
            _ -> value
          end

        ["#{Map.get(labels, key, key)}: #{rendered}" | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp active_governance_role_filters(filters) do
    labels = %{q: "Search", enabled: "Status"}

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

  defp fetch_governance_filter(filters, key) do
    filters
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
  end

  defp maybe_put_governance_filter(filters, _key, ""), do: filters
  defp maybe_put_governance_filter(filters, _key, nil), do: filters
  defp maybe_put_governance_filter(filters, key, value), do: Keyword.put(filters, key, value)

  defp normalize_governance_status_filter(""), do: nil

  defp normalize_governance_status_filter(value) when value in ["active", "repealed"] do
    String.to_atom(value)
  end

  defp normalize_governance_status_filter(_), do: nil

  defp normalize_governance_kind_filter(""), do: nil

  defp normalize_governance_kind_filter(value) when value in ["general", "voting_policy"] do
    String.to_atom(value)
  end

  defp normalize_governance_kind_filter(_), do: nil

  defp normalize_governance_enabled_filter(""), do: nil
  defp normalize_governance_enabled_filter("true"), do: true
  defp normalize_governance_enabled_filter("false"), do: false
  defp normalize_governance_enabled_filter(_), do: nil

  defp normalize_governance_proposal_type(value)
       when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_governance_proposal_type()
  end

  defp normalize_governance_proposal_type(value)
       when value in ["create", "amend", "repeal"] do
    value
  end

  defp normalize_governance_proposal_type(_), do: "create"

  defp sanitize_constitution_proposal_params(params) do
    rule_config = %{
      "approval_mode" =>
        params |> Map.get("approval_mode", "majority") |> to_string() |> String.trim(),
      "approval_threshold_percent" =>
        params |> Map.get("approval_threshold_percent", "51") |> to_string() |> String.trim(),
      "quorum_percent" =>
        params |> Map.get("quorum_percent", "50") |> to_string() |> String.trim(),
      "voting_window_hours" =>
        params |> Map.get("voting_window_hours", "72") |> to_string() |> String.trim()
    }

    eligible_role_ids =
      params
      |> Map.get("eligible_role_ids", [])
      |> List.wrap()
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    %{
      "reference" => params |> Map.get("reference", "") |> to_string() |> String.trim(),
      "proposal_type" =>
        params
        |> Map.get("proposal_type", "create")
        |> to_string()
        |> normalize_governance_proposal_type(),
      "law_id" => trim_optional_governance_value(Map.get(params, "law_id", "")),
      "proposed_name" => params |> Map.get("proposed_name", "") |> to_string() |> String.trim(),
      "proposed_slug" => params |> Map.get("proposed_slug", "") |> to_string() |> String.trim(),
      "proposed_markdown_body" =>
        params |> Map.get("proposed_markdown_body", "") |> to_string() |> String.trim(),
      "proposed_law_kind" =>
        params |> Map.get("proposed_law_kind", "general") |> to_string() |> String.trim(),
      "reason" => params |> Map.get("reason", "") |> to_string() |> String.trim(),
      "voting_scope" =>
        params |> Map.get("voting_scope", "all_members") |> to_string() |> String.trim(),
      "room_id" => trim_optional_governance_value(Map.get(params, "room_id", "")),
      "eligible_role_ids" => eligible_role_ids,
      "voting_rule_snapshot" => rule_config,
      "rule_config" => rule_config
    }
  end

  defp sanitize_constitution_role_params(params) do
    %{
      "name" => params |> Map.get("name", "") |> to_string() |> String.trim(),
      "slug" => params |> Map.get("slug", "") |> to_string() |> String.trim(),
      "description" => params |> Map.get("description", "") |> to_string() |> String.trim(),
      "enabled" => truthy?(Map.get(params, "enabled", "false"))
    }
  end

  defp sanitize_constitution_role_assignment_params(params) do
    %{
      "user_id" => params |> Map.get("user_id", "") |> to_string() |> String.trim()
    }
  end

  defp trim_optional_governance_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_metadata_json(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> {:ok, %{}}
      true -> Jason.decode(trimmed)
    end
  rescue
    _ -> {:error, :invalid_metadata}
  end

  defp parse_metadata_json(value) when is_map(value), do: {:ok, value}
  defp parse_metadata_json(_), do: {:ok, %{}}

  defp fetch_directory_filter(filters, key) do
    filters
    |> Map.get(key, "")
    |> to_string()
    |> String.trim()
  end

  defp default_task_timezone do
    System.get_env("AUTOMATA_DEFAULT_TIMEZONE", "Etc/UTC")
  end
end
