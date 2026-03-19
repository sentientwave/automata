defmodule SentientwaveAutomata.Agents do
  @moduledoc """
  Agent registry, mentions, durable run tracking, and RAG memory APIs.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents.{
    AgentWallet,
    AgentProfile,
    LLMTrace,
    Memory,
    Mention,
    Run,
    Skill,
    ToolPermission
  }

  alias SentientwaveAutomata.Repo

  @spec list_agents() :: [AgentProfile.t()]
  def list_agents do
    Repo.all(from a in AgentProfile, order_by: [asc: a.slug])
  end

  @spec list_active_agents() :: [AgentProfile.t()]
  def list_active_agents do
    Repo.all(from a in AgentProfile, where: a.status == :active, order_by: [asc: a.slug])
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

  @spec list_agent_skills(binary()) :: [Skill.t()]
  def list_agent_skills(agent_id) do
    Repo.all(
      from s in Skill,
        where: s.agent_id == ^agent_id and s.enabled == true,
        order_by: [asc: s.name, desc: s.version]
    )
  end

  @spec upsert_skill(map()) :: {:ok, Skill.t()} | {:error, Ecto.Changeset.t()}
  def upsert_skill(attrs) do
    agent_id = Map.get(attrs, :agent_id, Map.get(attrs, "agent_id"))
    name = Map.get(attrs, :name, Map.get(attrs, "name"))
    version = Map.get(attrs, :version, Map.get(attrs, "version", "v1"))

    case Repo.get_by(Skill, agent_id: agent_id, name: name, version: version) do
      nil -> %Skill{}
      existing -> existing
    end
    |> Skill.changeset(attrs)
    |> Repo.insert_or_update()
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
    run
    |> Run.changeset(attrs)
    |> Repo.update()
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

    Repo.all(
      from t in LLMTrace,
        preload: [:agent, :run, :mention, :provider_config],
        order_by: [desc: t.requested_at, desc: t.inserted_at],
        limit: ^limit
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
end
