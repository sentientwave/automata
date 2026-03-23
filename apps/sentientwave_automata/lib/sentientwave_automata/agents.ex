defmodule SentientwaveAutomata.Agents do
  @moduledoc """
  Agent registry, mentions, durable run tracking, and RAG memory APIs.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents.{
    AgentWallet,
    AgentProfile,
    LegacySkill,
    LLMTrace,
    Memory,
    Mention,
    Run,
    ScheduledTask,
    ScheduledTaskSchedule,
    Skill,
    SkillDesignation,
    ToolPermission
  }

  alias SentientwaveAutomata.Repo

  @spec list_agents(keyword()) :: [AgentProfile.t()]
  def list_agents(opts \\ []) do
    AgentProfile
    |> maybe_filter_agent_status(opts)
    |> maybe_filter_agent_kind(opts)
    |> order_by([a], asc: a.slug)
    |> Repo.all()
  end

  @spec list_active_agents() :: [AgentProfile.t()]
  def list_active_agents do
    list_agents(active_only: true)
  end

  @spec get_agent(binary()) :: AgentProfile.t() | nil
  def get_agent(id), do: Repo.get(AgentProfile, id)

  @spec get_agent_by_slug(String.t()) :: AgentProfile.t() | nil
  def get_agent_by_slug(slug), do: Repo.get_by(AgentProfile, slug: slug)

  @spec get_agent_by_localpart(String.t()) :: AgentProfile.t() | nil
  def get_agent_by_localpart(localpart),
    do: Repo.get_by(AgentProfile, matrix_localpart: localpart)

  @spec ensure_agent_from_directory(String.t()) :: AgentProfile.t() | nil
  def ensure_agent_from_directory(localpart) when is_binary(localpart) do
    normalized = localpart |> String.downcase() |> String.trim()

    case get_agent_by_localpart(normalized) do
      nil ->
        SentientwaveAutomata.Matrix.Directory.list_users()
        |> Enum.find(fn user -> user.localpart == normalized and user.kind == :agent end)
        |> case do
          nil ->
            nil

          user ->
            {:ok, profile} =
              upsert_agent(%{
                slug: normalized,
                kind: :agent,
                display_name: user.display_name,
                matrix_localpart: normalized,
                status: :active,
                metadata: %{source: "matrix_directory"}
              })

            _ =
              upsert_agent_wallet(profile.id, %{
                kind: "personal",
                status: "active",
                matrix_credentials: %{
                  localpart: user.localpart,
                  mxid:
                    "@#{user.localpart}:#{System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")}",
                  password: user.password,
                  homeserver_url: System.get_env("MATRIX_URL", "http://localhost:8008")
                },
                metadata: %{source: "matrix_directory"}
              })

            profile
        end

      profile ->
        profile
    end
  end

  @spec upsert_agent(map()) :: {:ok, AgentProfile.t()} | {:error, Ecto.Changeset.t()}
  def upsert_agent(attrs) do
    slug = Map.get(attrs, :slug, Map.get(attrs, "slug", ""))

    case Repo.get_by(AgentProfile, slug: slug) do
      nil -> %AgentProfile{}
      existing -> existing
    end
    |> AgentProfile.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec list_skills(keyword()) :: [Skill.t()]
  def list_skills(opts \\ []) do
    Skill
    |> preload([:designations])
    |> maybe_filter_skill_enabled(opts)
    |> maybe_search_skills(Keyword.get(opts, :q))
    |> order_by([s], asc: s.name, asc: s.slug)
    |> Repo.all()
  end

  @spec count_skills(keyword()) :: non_neg_integer()
  def count_skills(opts \\ []) do
    Skill
    |> maybe_filter_skill_enabled(opts)
    |> maybe_search_skills(Keyword.get(opts, :q))
    |> Repo.aggregate(:count, :id)
  end

  @spec get_skill(binary()) :: Skill.t() | nil
  def get_skill(id) when is_binary(id) do
    Repo.one(
      from s in Skill,
        where: s.id == ^id,
        preload: [designations: ^designation_preload_query()]
    )
  end

  @spec get_skill_by_slug(String.t()) :: Skill.t() | nil
  def get_skill_by_slug(slug) when is_binary(slug), do: Repo.get_by(Skill, slug: slug)

  @spec create_skill(map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def create_skill(attrs) when is_map(attrs) do
    attrs = normalize_skill_attrs(attrs)

    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_skill(Skill.t(), map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def update_skill(%Skill{} = skill, attrs) when is_map(attrs) do
    attrs = normalize_skill_attrs(attrs)

    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  @spec list_agent_skills(binary()) :: [Skill.t()]
  def list_agent_skills(agent_id) do
    Repo.all(
      from s in Skill,
        join: d in SkillDesignation,
        on: d.skill_id == s.id,
        where: d.agent_id == ^agent_id and d.status == :active and s.enabled == true,
        order_by: [asc: s.name, asc: s.slug]
    )
  end

  @spec list_skill_designations(binary(), keyword()) :: [SkillDesignation.t()]
  def list_skill_designations(skill_id, opts \\ []) when is_binary(skill_id) do
    SkillDesignation
    |> where([d], d.skill_id == ^skill_id)
    |> maybe_filter_designation_status(opts)
    |> preload([:agent, :skill])
    |> order_by([d], desc: d.designated_at, desc: d.inserted_at)
    |> Repo.all()
  end

  @spec count_skill_designations(binary(), keyword()) :: non_neg_integer()
  def count_skill_designations(skill_id, opts \\ []) when is_binary(skill_id) do
    SkillDesignation
    |> where([d], d.skill_id == ^skill_id)
    |> maybe_filter_designation_status(opts)
    |> Repo.aggregate(:count, :id)
  end

  @spec designate_skill(binary(), binary(), map()) ::
          {:ok, SkillDesignation.t()} | {:error, Ecto.Changeset.t() | term()}
  def designate_skill(skill_id, agent_id, attrs \\ %{})
      when is_binary(skill_id) and is_binary(agent_id) and is_map(attrs) do
    case Repo.get_by(SkillDesignation, skill_id: skill_id, agent_id: agent_id, status: :active) do
      %SkillDesignation{} = designation ->
        {:ok, Repo.preload(designation, designation_preloads())}

      nil ->
        designation_attrs =
          attrs
          |> Map.put(:skill_id, skill_id)
          |> Map.put(:agent_id, agent_id)
          |> Map.put_new(:status, :active)
          |> Map.put_new(:designated_at, DateTime.utc_now())

        %SkillDesignation{}
        |> SkillDesignation.changeset(designation_attrs)
        |> Repo.insert()
        |> case do
          {:ok, designation} -> {:ok, Repo.preload(designation, designation_preloads())}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec rollback_skill_designation(binary(), map()) ::
          {:ok, SkillDesignation.t()} | {:error, Ecto.Changeset.t() | term()}
  def rollback_skill_designation(designation_id, attrs \\ %{})
      when is_binary(designation_id) and is_map(attrs) do
    case Repo.get(SkillDesignation, designation_id) do
      nil ->
        {:error, :not_found}

      %SkillDesignation{status: :rolled_back} = designation ->
        {:ok, Repo.preload(designation, designation_preloads())}

      %SkillDesignation{} = designation ->
        designation
        |> SkillDesignation.changeset(
          attrs
          |> Map.put(:status, :rolled_back)
          |> Map.put_new(:rolled_back_at, DateTime.utc_now())
        )
        |> Repo.update()
        |> case do
          {:ok, designation} -> {:ok, Repo.preload(designation, designation_preloads())}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec upsert_skill(map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def upsert_skill(attrs) do
    agent_id = Map.get(attrs, :agent_id, Map.get(attrs, "agent_id"))

    skill_attrs =
      attrs
      |> normalize_skill_attrs()
      |> Map.drop([:agent_id, "agent_id", :markdown_path, "markdown_path", :version, "version"])

    with {:ok, skill} <- upsert_global_skill(skill_attrs),
         :ok <- maybe_record_legacy_skill(attrs, skill.id),
         {:ok, _designation} <- maybe_designate_imported_skill(skill, agent_id, attrs) do
      {:ok, skill}
    end
  end

  @spec set_tool_permission(map()) :: {:ok, ToolPermission.t()} | {:error, Ecto.Changeset.t()}
  def set_tool_permission(attrs) do
    agent_id = Map.get(attrs, :agent_id, Map.get(attrs, "agent_id"))
    tool_name = Map.get(attrs, :tool_name, Map.get(attrs, "tool_name"))
    scope = Map.get(attrs, :scope, Map.get(attrs, "scope", "default"))

    case Repo.get_by(ToolPermission, agent_id: agent_id, tool_name: tool_name, scope: scope) do
      nil -> %ToolPermission{}
      existing -> existing
    end
    |> ToolPermission.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @spec allowed_tool?(binary(), String.t(), String.t()) :: boolean()
  def allowed_tool?(agent_id, tool_name, scope \\ "default") do
    case get_tool_permission(agent_id, tool_name, scope) do
      nil -> true
      permission -> permission.allowed
    end
  end

  @spec get_tool_permission(binary(), String.t(), String.t()) :: ToolPermission.t() | nil
  def get_tool_permission(agent_id, tool_name, scope \\ "default") do
    Repo.get_by(ToolPermission, agent_id: agent_id, tool_name: tool_name, scope: scope)
  end

  @spec reset_tool_permission(binary(), String.t(), String.t()) :: :ok
  def reset_tool_permission(agent_id, tool_name, scope \\ "default") do
    from(p in ToolPermission,
      where: p.agent_id == ^agent_id and p.tool_name == ^tool_name and p.scope == ^scope
    )
    |> Repo.delete_all()

    :ok
  end

  @spec list_tool_permissions_for_agent(binary()) :: [ToolPermission.t()]
  def list_tool_permissions_for_agent(agent_id) when is_binary(agent_id) do
    Repo.all(
      from p in ToolPermission,
        where: p.agent_id == ^agent_id,
        order_by: [asc: p.tool_name, asc: p.scope]
    )
  end

  @spec create_mention(map()) :: {:ok, Mention.t()} | {:error, Ecto.Changeset.t()}
  def create_mention(attrs) do
    %Mention{}
    |> Mention.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_mention_by_message_id(String.t()) :: Mention.t() | nil
  def get_mention_by_message_id(message_id), do: Repo.get_by(Mention, message_id: message_id)

  @spec list_runs(keyword()) :: [Run.t()]
  def list_runs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    query =
      from r in Run,
        preload: [:agent, :mention],
        order_by: [desc: r.inserted_at],
        limit: ^limit

    Repo.all(query)
  end

  @spec get_run(binary()) :: Run.t() | nil
  def get_run(id), do: Repo.get(Run, id)

  @spec create_run(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_run(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%Run{} = run, attrs) do
    attrs = normalize_run_update_attrs(attrs)

    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  @spec mark_orphaned_runs_failed() :: non_neg_integer()
  def mark_orphaned_runs_failed do
    {count, _rows} =
      from(r in Run,
        where: r.status == :running,
        where: fragment("coalesce((?->>'temporal_source'), '')", r.metadata) != ^"temporal_sdk"
      )
      |> Repo.update_all(
        set: [
          status: :failed,
          error: %{
            "reason" => "Run abandoned during Temporal-only workflow cutover.",
            "kind" => "temporal_cutover_orphan"
          },
          updated_at: DateTime.utc_now()
        ]
      )

    count
  end

  @spec create_memory(map()) :: {:ok, Memory.t()} | {:error, Ecto.Changeset.t()}
  def create_memory(attrs) do
    %Memory{}
    |> Memory.changeset(attrs)
    |> Repo.insert()
  end

  @spec create_llm_trace(map()) :: {:ok, LLMTrace.t()} | {:error, Ecto.Changeset.t()}
  def create_llm_trace(attrs) do
    %LLMTrace{}
    |> LLMTrace.changeset(attrs)
    |> Repo.insert()
  end

  @spec list_llm_traces(keyword()) :: [LLMTrace.t()]
  def list_llm_traces(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    filters = Keyword.get(opts, :filters, %{})

    Repo.all(
      from(t in LLMTrace,
        preload: [:agent, :run, :mention, :provider_config],
        order_by: [desc: t.requested_at, desc: t.inserted_at],
        limit: ^limit
      )
      |> apply_llm_trace_filters(filters)
    )
  end

  @spec count_llm_traces(keyword()) :: non_neg_integer()
  def count_llm_traces(opts \\ []) do
    filters = Keyword.get(opts, :filters, %{})

    LLMTrace
    |> apply_llm_trace_filters(filters)
    |> Repo.aggregate(:count, :id)
  end

  @spec get_llm_trace(binary()) :: LLMTrace.t() | nil
  def get_llm_trace(id) when is_binary(id) do
    Repo.one(
      from t in LLMTrace,
        where: t.id == ^id,
        preload: [:agent, :run, :mention, :provider_config]
    )
  end

  @spec list_memories_for_agent(binary()) :: [Memory.t()]
  def list_memories_for_agent(agent_id) do
    Repo.all(from m in Memory, where: m.agent_id == ^agent_id, order_by: [desc: m.inserted_at])
  end

  @spec get_agent_wallet(binary()) :: AgentWallet.t() | nil
  def get_agent_wallet(agent_id) when is_binary(agent_id) do
    Repo.get_by(AgentWallet, agent_id: agent_id)
  end

  @spec upsert_agent_wallet(binary(), map()) ::
          {:ok, AgentWallet.t()} | {:error, Ecto.Changeset.t()}
  def upsert_agent_wallet(agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    case Repo.get_by(AgentWallet, agent_id: agent_id) do
      nil -> %AgentWallet{agent_id: agent_id}
      existing -> existing
    end
    |> AgentWallet.changeset(Map.put(attrs, :agent_id, agent_id))
    |> Repo.insert_or_update()
  end

  @spec list_scheduled_tasks(binary()) :: [ScheduledTask.t()]
  def list_scheduled_tasks(agent_id) when is_binary(agent_id) do
    Repo.all(
      from t in ScheduledTask,
        where: t.agent_id == ^agent_id,
        preload: [:agent],
        order_by: [asc: t.enabled, asc: t.next_run_at, asc: t.name]
    )
  end

  @spec get_scheduled_task(binary()) :: ScheduledTask.t() | nil
  def get_scheduled_task(id) when is_binary(id) do
    Repo.one(
      from t in ScheduledTask,
        where: t.id == ^id,
        preload: [:agent]
    )
  end

  @spec create_scheduled_task(binary(), map()) ::
          {:ok, ScheduledTask.t()} | {:error, Ecto.Changeset.t() | term()}
  def create_scheduled_task(agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    attrs =
      attrs
      |> normalize_scheduled_task_attrs()
      |> Map.put(:agent_id, agent_id)

    %ScheduledTask{}
    |> ScheduledTask.changeset(attrs)
    |> put_initial_next_run()
    |> Repo.insert()
    |> case do
      {:ok, task} ->
        task = Repo.preload(task, [:agent])
        notify_scheduled_task_reconciler()
        {:ok, task}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec update_scheduled_task(ScheduledTask.t(), map()) ::
          {:ok, ScheduledTask.t()} | {:error, Ecto.Changeset.t() | term()}
  def update_scheduled_task(%ScheduledTask{} = task, attrs) when is_map(attrs) do
    attrs = normalize_scheduled_task_attrs(attrs)

    task
    |> ScheduledTask.changeset(attrs)
    |> put_initial_next_run()
    |> Repo.update()
    |> case do
      {:ok, updated_task} ->
        updated_task = Repo.preload(updated_task, [:agent])
        notify_scheduled_task_reconciler()
        {:ok, updated_task}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @spec delete_scheduled_task(ScheduledTask.t()) :: :ok | {:error, term()}
  def delete_scheduled_task(%ScheduledTask{} = task) do
    case Repo.delete(task) do
      {:ok, _task} ->
        notify_scheduled_task_reconciler()
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec set_scheduled_task_enabled(ScheduledTask.t(), boolean()) ::
          {:ok, ScheduledTask.t()} | {:error, Ecto.Changeset.t() | term()}
  def set_scheduled_task_enabled(%ScheduledTask{} = task, enabled) when is_boolean(enabled) do
    attrs =
      if enabled do
        %{enabled: true}
      else
        %{enabled: false, next_run_at: nil}
      end

    update_scheduled_task(task, attrs)
  end

  @spec list_due_scheduled_tasks(keyword()) :: [ScheduledTask.t()]
  def list_due_scheduled_tasks(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.all(
      from t in ScheduledTask,
        where: t.enabled == true and not is_nil(t.next_run_at) and t.next_run_at <= ^now,
        preload: [:agent],
        order_by: [asc: t.next_run_at, asc: t.inserted_at],
        limit: ^limit
    )
  end

  @spec list_enabled_scheduled_tasks() :: [ScheduledTask.t()]
  def list_enabled_scheduled_tasks do
    Repo.all(
      from t in ScheduledTask,
        where: t.enabled == true,
        preload: [:agent],
        order_by: [asc: t.next_run_at, asc: t.inserted_at]
    )
  end

  @spec list_temporal_managed_scheduled_tasks() :: [ScheduledTask.t()]
  def list_temporal_managed_scheduled_tasks do
    Repo.all(
      from t in ScheduledTask,
        where: not is_nil(t.workflow_id),
        preload: [:agent],
        order_by: [asc: t.updated_at]
    )
  end

  @spec claim_scheduled_task(ScheduledTask.t()) ::
          {:ok, ScheduledTask.t()} | {:error, :stale | Ecto.Changeset.t() | term()}
  def claim_scheduled_task(%ScheduledTask{} = task) do
    with {:ok, next_run_at} <-
           ScheduledTaskSchedule.next_run_after(task, task.next_run_at || DateTime.utc_now()) do
      {count, _} =
        from(t in ScheduledTask,
          where:
            t.id == ^task.id and t.enabled == true and not is_nil(t.next_run_at) and
              t.next_run_at == ^task.next_run_at
        )
        |> Repo.update_all(set: [next_run_at: next_run_at, updated_at: DateTime.utc_now()])

      if count == 1 do
        {:ok, Repo.preload(%{task | next_run_at: next_run_at}, [:agent])}
      else
        {:error, :stale}
      end
    end
  end

  @spec record_scheduled_task_result(ScheduledTask.t(), map()) ::
          {:ok, ScheduledTask.t()} | {:error, Ecto.Changeset.t()}
  def record_scheduled_task_result(%ScheduledTask{} = task, outcome) when is_map(outcome) do
    task
    |> ScheduledTask.changeset(%{
      last_run_at: DateTime.utc_now(),
      last_outcome: outcome
    })
    |> Repo.update()
  end

  @spec update_scheduled_task_temporal_state(ScheduledTask.t(), map()) ::
          {:ok, ScheduledTask.t()} | {:error, Ecto.Changeset.t()}
  def update_scheduled_task_temporal_state(%ScheduledTask{} = task, attrs) when is_map(attrs) do
    task
    |> ScheduledTask.changeset(attrs)
    |> Repo.update()
  end

  defp upsert_global_skill(attrs) do
    slug = Map.get(attrs, :slug, Map.get(attrs, "slug", ""))

    case Repo.get_by(Skill, slug: slug) do
      nil -> %Skill{}
      existing -> existing
    end
    |> Skill.changeset(attrs)
    |> Repo.insert_or_update()
  end

  defp maybe_designate_imported_skill(skill, agent_id, attrs)
       when is_binary(agent_id) and agent_id != "" do
    metadata =
      attrs
      |> Map.get(:metadata, Map.get(attrs, "metadata", %{}))
      |> normalize_map()
      |> Map.put("source", "legacy_skill_import")

    designate_skill(skill.id, agent_id, %{metadata: metadata})
  end

  defp maybe_designate_imported_skill(_skill, _agent_id, _attrs), do: {:ok, nil}

  defp maybe_record_legacy_skill(attrs, skill_id) do
    agent_id = Map.get(attrs, :agent_id, Map.get(attrs, "agent_id"))
    markdown_body = Map.get(attrs, :markdown_body, Map.get(attrs, "markdown_body", ""))

    if is_binary(agent_id) and agent_id != "" and is_binary(markdown_body) and markdown_body != "" do
      legacy_attrs =
        attrs
        |> Map.put(:agent_id, agent_id)
        |> Map.put(:name, Map.get(attrs, :name, Map.get(attrs, "name", "Skill")))
        |> Map.put(:markdown_body, markdown_body)
        |> Map.put(:version, Map.get(attrs, :version, Map.get(attrs, "version", "v1")))
        |> Map.put(
          :metadata,
          attrs
          |> Map.get(:metadata, Map.get(attrs, "metadata", %{}))
          |> normalize_map()
          |> Map.put("migrated_skill_id", skill_id)
        )

      case Repo.get_by(LegacySkill,
             agent_id: agent_id,
             name: Map.get(legacy_attrs, :name),
             version: Map.get(legacy_attrs, :version)
           ) do
        nil -> %LegacySkill{}
        existing -> existing
      end
      |> LegacySkill.changeset(legacy_attrs)
      |> Repo.insert_or_update()
      |> case do
        {:ok, _legacy} -> :ok
        {:error, _changeset} -> :ok
      end
    else
      :ok
    end
  end

  defp apply_llm_trace_filters(query, filters) when is_map(filters) do
    query
    |> maybe_filter_llm_trace(:provider, fetch_filter(filters, :provider))
    |> maybe_filter_llm_trace(:status, fetch_filter(filters, :status))
    |> maybe_filter_llm_trace(:call_kind, fetch_filter(filters, :call_kind))
    |> maybe_filter_llm_trace(:requester_kind, fetch_filter(filters, :requester_kind))
    |> maybe_filter_llm_trace(:conversation_scope, fetch_filter(filters, :conversation_scope))
    |> maybe_search_llm_traces(fetch_filter(filters, :q))
  end

  defp apply_llm_trace_filters(query, _filters), do: query

  defp maybe_filter_llm_trace(query, _field, nil), do: query

  defp maybe_filter_llm_trace(query, field_name, value) do
    where(query, [t], field(t, ^field_name) == ^value)
  end

  defp maybe_search_llm_traces(query, nil), do: query

  defp maybe_search_llm_traces(query, value) do
    like = "%" <> value <> "%"

    where(
      query,
      [t],
      ilike(t.provider, ^like) or
        ilike(t.model, ^like) or
        ilike(fragment("coalesce(?, '')", t.requester_mxid), ^like) or
        ilike(fragment("coalesce(?, '')", t.requester_display_name), ^like) or
        ilike(fragment("coalesce(?, '')", t.requester_localpart), ^like) or
        ilike(fragment("coalesce(?, '')", t.room_id), ^like) or
        ilike(fragment("coalesce(?, '')", t.call_kind), ^like) or
        ilike(fragment("coalesce(cast(? as text), '')", t.request_payload), ^like) or
        ilike(fragment("coalesce(cast(? as text), '')", t.response_payload), ^like) or
        ilike(fragment("coalesce(cast(? as text), '')", t.error_payload), ^like)
    )
  end

  defp notify_scheduled_task_reconciler do
    case Process.whereis(SentientwaveAutomata.Agents.ScheduledTaskReconciler) do
      nil -> :ok
      pid -> send(pid, :reconcile)
    end
  end

  defp fetch_filter(filters, key) do
    filters
    |> Map.get(key, Map.get(filters, Atom.to_string(key)))
    |> case do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      nil ->
        nil

      value ->
        value
    end
  end

  defp maybe_filter_agent_status(query, opts) do
    if Keyword.get(opts, :active_only, false) do
      where(query, [a], a.status == :active)
    else
      query
    end
  end

  defp maybe_filter_agent_kind(query, opts) do
    case Keyword.get(opts, :kind) do
      nil -> query
      kind -> where(query, [a], a.kind == ^kind)
    end
  end

  defp maybe_filter_skill_enabled(query, opts) do
    case Keyword.get(opts, :enabled) do
      nil -> query
      value -> where(query, [s], s.enabled == ^value)
    end
  end

  defp maybe_search_skills(query, nil), do: query
  defp maybe_search_skills(query, ""), do: query

  defp maybe_search_skills(query, value) do
    like = "%" <> String.trim(to_string(value)) <> "%"

    where(
      query,
      [s],
      ilike(s.name, ^like) or
        ilike(s.slug, ^like) or
        ilike(s.markdown_body, ^like)
    )
  end

  defp maybe_filter_designation_status(query, opts) do
    case Keyword.get(opts, :status) do
      nil ->
        query

      status when is_list(status) ->
        where(query, [d], d.status in ^status)

      status ->
        where(query, [d], d.status == ^status)
    end
  end

  defp normalize_skill_attrs(attrs) do
    attrs
    |> maybe_put_key(:slug, Map.get(attrs, :name, Map.get(attrs, "name")))
    |> maybe_put_key(:enabled, true)
    |> maybe_put_key(:metadata, %{})
  end

  defp normalize_run_update_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_run_update_key(key), value)
    end)
  end

  defp normalize_run_update_attrs(attrs), do: attrs

  defp normalize_run_update_key(key) when key in [:agent_id, "agent_id"], do: :agent_id
  defp normalize_run_update_key(key) when key in [:mention_id, "mention_id"], do: :mention_id
  defp normalize_run_update_key(key) when key in [:workflow_id, "workflow_id"], do: :workflow_id

  defp normalize_run_update_key(key) when key in [:temporal_run_id, "temporal_run_id"],
    do: :temporal_run_id

  defp normalize_run_update_key(key) when key in [:status, "status"], do: :status
  defp normalize_run_update_key(key) when key in [:error, "error"], do: :error
  defp normalize_run_update_key(key) when key in [:result, "result"], do: :result
  defp normalize_run_update_key(key) when key in [:metadata, "metadata"], do: :metadata
  defp normalize_run_update_key(key), do: key

  defp maybe_put_key(map, _key, nil), do: map

  defp maybe_put_key(map, key, value) do
    cond do
      Map.has_key?(map, key) -> map
      Map.has_key?(map, Atom.to_string(key)) -> map
      true -> Map.put(map, key, value)
    end
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp normalize_scheduled_task_attrs(attrs) do
    attrs
    |> Map.take([
      :name,
      "name",
      :enabled,
      "enabled",
      :task_type,
      "task_type",
      :schedule_type,
      "schedule_type",
      :schedule_interval,
      "schedule_interval",
      :schedule_hour,
      "schedule_hour",
      :schedule_minute,
      "schedule_minute",
      :schedule_weekday,
      "schedule_weekday",
      :timezone,
      "timezone",
      :room_id,
      "room_id",
      :prompt_body,
      "prompt_body",
      :message_body,
      "message_body",
      :metadata,
      "metadata",
      :next_run_at,
      "next_run_at"
    ])
    |> normalize_key(:name, fn value -> value |> to_string() |> String.trim() end)
    |> normalize_key(:enabled, &truthy_value/1)
    |> normalize_key(:task_type, &normalize_task_type/1)
    |> normalize_key(:schedule_type, &normalize_schedule_type/1)
    |> normalize_key(:schedule_interval, &normalize_integer(&1, 1))
    |> normalize_key(:schedule_hour, &normalize_optional_integer/1)
    |> normalize_key(:schedule_minute, &normalize_integer(&1, 0))
    |> normalize_key(:schedule_weekday, &normalize_optional_integer/1)
    |> normalize_key(:timezone, fn value ->
      value |> to_string() |> String.trim() |> default_timezone()
    end)
    |> normalize_key(:room_id, fn value -> value |> to_string() |> String.trim() end)
    |> normalize_key(:prompt_body, fn value -> value |> to_string() |> String.trim() end)
    |> normalize_key(:message_body, fn value -> value |> to_string() |> String.trim() end)
    |> normalize_key(:metadata, &normalize_map/1)
  end

  defp put_initial_next_run(%Ecto.Changeset{} = changeset) do
    enabled = Ecto.Changeset.get_field(changeset, :enabled)

    cond do
      enabled == false ->
        Ecto.Changeset.put_change(changeset, :next_run_at, nil)

      true ->
        case ScheduledTaskSchedule.initial_next_run(Ecto.Changeset.apply_changes(changeset)) do
          {:ok, next_run_at} ->
            Ecto.Changeset.put_change(changeset, :next_run_at, next_run_at)

          {:error, _reason} ->
            changeset
        end
    end
  end

  defp normalize_key(map, key, transform) do
    cond do
      Map.has_key?(map, key) ->
        Map.update!(map, key, transform)

      Map.has_key?(map, Atom.to_string(key)) ->
        map
        |> Map.put(key, transform.(Map.get(map, Atom.to_string(key))))
        |> Map.delete(Atom.to_string(key))

      true ->
        map
    end
  end

  defp normalize_task_type(value) when value in [:run_agent_prompt, "run_agent_prompt"],
    do: :run_agent_prompt

  defp normalize_task_type(value) when value in [:post_room_message, "post_room_message"],
    do: :post_room_message

  defp normalize_task_type(_), do: :run_agent_prompt

  defp normalize_schedule_type(value) when value in [:hourly, "hourly"], do: :hourly
  defp normalize_schedule_type(value) when value in [:daily, "daily"], do: :daily
  defp normalize_schedule_type(value) when value in [:weekly, "weekly"], do: :weekly
  defp normalize_schedule_type(_), do: :daily

  defp normalize_integer(value, _default) when is_integer(value), do: value

  defp normalize_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> default
    end
  end

  defp normalize_integer(_value, default), do: default

  defp normalize_optional_integer(value) when value in [nil, ""], do: nil

  defp normalize_optional_integer(value) when is_integer(value), do: value

  defp normalize_optional_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      :error -> nil
    end
  end

  defp normalize_optional_integer(_), do: nil

  defp truthy_value(value), do: value in [true, "true", "1", 1, "on"]

  defp default_timezone(""), do: "Etc/UTC"
  defp default_timezone(value), do: value

  defp designation_preloads, do: [:agent, :skill]

  defp designation_preload_query do
    from d in SkillDesignation,
      preload: [:agent],
      order_by: [desc: d.designated_at, desc: d.inserted_at]
  end
end
