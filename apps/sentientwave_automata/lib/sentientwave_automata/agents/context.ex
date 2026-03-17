defmodule SentientwaveAutomata.Agents.Runtime do
  @moduledoc """
  Agent directory and durable runtime data access.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents.{
    AgentProfile,
    Memory,
    Mention,
    Run,
    Skill,
    ToolPermission
  }

  alias SentientwaveAutomata.Repo

  @doc """
  Lists registered agents.
  """
  def list_agents(opts \\ []) do
    AgentProfile
    |> maybe_active_only(opts)
    |> order_by([a], asc: a.display_name, asc: a.slug)
    |> Repo.all()
  end

  def get_agent!(id), do: Repo.get!(AgentProfile, id)

  def get_agent_by_handle(handle) when is_binary(handle) do
    normalized = normalize_handle(handle)
    Repo.get_by(AgentProfile, slug: normalized)
  end

  def create_agent(attrs) when is_map(attrs) do
    attrs = normalize_agent_attrs(attrs)

    %AgentProfile{}
    |> AgentProfile.changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%AgentProfile{} = agent, attrs) do
    attrs = normalize_agent_attrs(attrs)

    agent
    |> AgentProfile.changeset(attrs)
    |> Repo.update()
  end

  def delete_agent(%AgentProfile{} = agent), do: Repo.delete(agent)

  def change_agent(%AgentProfile{} = agent, attrs \\ %{}) do
    AgentProfile.changeset(agent, normalize_agent_attrs(attrs))
  end

  def create_skill(attrs) when is_map(attrs) do
    %Skill{}
    |> Skill.changeset(attrs)
    |> Repo.insert()
  end

  def list_skills(agent_id, opts \\ []) when is_binary(agent_id) do
    Skill
    |> where([s], s.agent_id == ^agent_id)
    |> maybe_skill_enabled_only(opts)
    |> order_by([s], asc: s.name, desc: s.version)
    |> Repo.all()
  end

  def update_skill(%Skill{} = skill, attrs) do
    skill
    |> Skill.changeset(attrs)
    |> Repo.update()
  end

  def create_or_update_tool_permission(attrs) when is_map(attrs) do
    changeset = ToolPermission.changeset(%ToolPermission{}, attrs)
    allowed = fetch_attr(attrs, :allowed, false)
    constraints = fetch_attr(attrs, :constraints, %{})

    Repo.insert(changeset,
      conflict_target: [:agent_id, :tool_name, :scope],
      on_conflict: [
        set: [
          allowed: allowed,
          constraints: constraints
        ]
      ],
      returning: true
    )
  end

  def list_tool_permissions(agent_id) when is_binary(agent_id) do
    ToolPermission
    |> where([p], p.agent_id == ^agent_id)
    |> order_by([p], asc: p.tool_name, asc: p.scope)
    |> Repo.all()
  end

  def create_mention(attrs) when is_map(attrs) do
    attrs = normalize_mention_attrs(attrs)

    %Mention{}
    |> Mention.changeset(attrs)
    |> Repo.insert()
  end

  def list_pending_mentions(limit \\ 20) when is_integer(limit) and limit > 0 do
    Mention
    |> where([m], m.status == :pending)
    |> order_by([m], asc: m.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def mark_mention_status(%Mention{} = mention, status, attrs \\ %{}) do
    status = normalize_status(status, Mention.__schema__(:type, :status), :pending)

    mention
    |> Mention.changeset(Map.merge(attrs, %{status: status, processed_at: processed_at(status)}))
    |> Repo.update()
  end

  def create_run(attrs) when is_map(attrs) do
    attrs = normalize_run_attrs(attrs)

    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  def get_run_by_workflow_id(workflow_id) when is_binary(workflow_id) do
    Repo.get_by(Run, workflow_id: workflow_id)
  end

  def mark_run_status(%Run{} = run, status, attrs \\ %{}) do
    status = normalize_status(status, Run.__schema__(:type, :status), :queued)

    run
    |> Run.changeset(Map.put(attrs, :status, status))
    |> Repo.update()
  end

  def create_memory(attrs) when is_map(attrs) do
    %Memory{}
    |> Memory.changeset(attrs)
    |> Repo.insert(returning: false)
  end

  @doc """
  Performs cosine similarity search in pgvector-backed memory.

  Returns maps with similarity score and metadata. Higher `score` is better.
  """
  def search_memories(agent_id, embedding, opts \\ [])
      when is_binary(agent_id) and is_list(embedding) do
    limit = Keyword.get(opts, :limit, 5)

    Memory
    |> where([m], m.agent_id == ^agent_id)
    |> select([m], %{
      id: m.id,
      content: m.content,
      source: m.source,
      metadata: m.metadata,
      inserted_at: m.inserted_at,
      embedding: m.embedding
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      Map.put(row, :score, cosine_similarity(row.embedding || [], embedding))
    end)
    |> Enum.sort_by(& &1.score, :desc)
    |> Enum.take(limit)
    |> Enum.map(&Map.delete(&1, :embedding))
  end

  defp maybe_active_only(query, opts) do
    if Keyword.get(opts, :active_only, false) do
      where(query, [a], a.status == :active)
    else
      query
    end
  end

  defp maybe_skill_enabled_only(query, opts) do
    if Keyword.get(opts, :enabled_only, false) do
      where(query, [s], s.enabled == true)
    else
      query
    end
  end

  defp normalize_agent_attrs(attrs) do
    attrs
    |> maybe_put_key(:slug, fetch_attr(attrs, :handle, nil))
    |> maybe_put_key(:display_name, fetch_attr(attrs, :name, nil))
    |> maybe_put_key(:kind, normalize_agent_kind(fetch_attr(attrs, :kind, nil)))
    |> maybe_put_key(:status, normalize_agent_status(fetch_attr(attrs, :is_active, nil)))
    |> maybe_update_key(:slug, &normalize_handle/1)
  end

  defp normalize_mention_attrs(attrs) do
    attrs
    |> maybe_put_key(:room_id, fetch_attr(attrs, :matrix_room_id, nil))
    |> maybe_put_key(:message_id, fetch_attr(attrs, :matrix_event_id, nil))
    |> maybe_put_key(:sender_mxid, fetch_attr(attrs, :mentioned_by, nil))
    |> maybe_put_key(:body, fetch_attr(attrs, :raw_text, nil))
    |> maybe_put_key(:raw_event, fetch_attr(attrs, :context, nil))
    |> maybe_put_key(
      :status,
      normalize_status(fetch_attr(attrs, :status, nil), Mention.__schema__(:type, :status), nil)
    )
  end

  defp normalize_run_attrs(attrs) do
    attrs
    |> maybe_put_key(:workflow_id, fetch_attr(attrs, :temporal_workflow_id, nil))
    |> maybe_put_key(:result, fetch_attr(attrs, :output, nil))
    |> maybe_put_key(:metadata, fetch_attr(attrs, :input, nil))
    |> maybe_put_key(
      :status,
      normalize_status(fetch_attr(attrs, :status, nil), Run.__schema__(:type, :status), nil)
    )
  end

  defp normalize_status(nil, _type, fallback), do: fallback

  defp normalize_status(value, type, fallback) do
    case Ecto.Type.cast(type, value) do
      {:ok, casted} -> casted
      :error -> fallback
    end
  end

  defp normalize_agent_kind(nil), do: nil
  defp normalize_agent_kind(:human), do: :person
  defp normalize_agent_kind("human"), do: :person
  defp normalize_agent_kind(:ai), do: :agent
  defp normalize_agent_kind("ai"), do: :agent
  defp normalize_agent_kind(kind), do: kind

  defp normalize_agent_status(nil), do: nil
  defp normalize_agent_status(true), do: :active
  defp normalize_agent_status(false), do: :disabled
  defp normalize_agent_status(status), do: status

  defp processed_at(:completed), do: DateTime.utc_now()
  defp processed_at(:failed), do: DateTime.utc_now()
  defp processed_at(:ignored), do: DateTime.utc_now()
  defp processed_at(_), do: nil

  defp normalize_handle(handle) when is_binary(handle) do
    handle
    |> String.trim()
    |> String.trim_leading("@")
    |> String.downcase()
  end

  defp normalize_handle(other), do: other

  defp maybe_put_key(map, _key, nil), do: map

  defp maybe_put_key(map, key, value) do
    if Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key)) do
      map
    else
      Map.put(map, key, value)
    end
  end

  defp maybe_update_key(map, key, fun) do
    cond do
      Map.has_key?(map, key) -> Map.update!(map, key, fun)
      Map.has_key?(map, Atom.to_string(key)) -> Map.update!(map, Atom.to_string(key), fun)
      true -> map
    end
  end

  defp fetch_attr(attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp cosine_similarity([], _), do: 0.0
  defp cosine_similarity(_, []), do: 0.0

  defp cosine_similarity(a, b) do
    len = min(length(a), length(b))
    a = Enum.take(a, len)
    b = Enum.take(b, len)

    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    na = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    nb = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (na * nb)
  end
end
