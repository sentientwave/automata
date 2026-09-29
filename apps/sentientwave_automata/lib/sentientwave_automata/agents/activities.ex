defmodule SentientwaveAutomata.Agents.Activities do
  @moduledoc """
  Agent workflow activities.

  Activities are side-effecting steps suitable for execution by Temporal workers.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.LLM.Client
  alias SentientwaveAutomata.Agents.MemoryStore
  alias SentientwaveAutomata.Agents.Mention
  alias SentientwaveAutomata.Agents.RAG
  alias SentientwaveAutomata.Agents.Run
  alias SentientwaveAutomata.Agents.Runtime
  alias SentientwaveAutomata.Repo
  require Logger

  @spec build_context(Run.t(), map()) :: {:ok, map()} | {:error, term()}
  def build_context(%Run{} = run, attrs) do
    agent_id = run.agent_id || fetch_value(attrs, "agent_id")
    room_id = fetch_value(attrs, "room_id", "")
    query = attrs |> fetch_map("input") |> fetch_value("body", "") |> sanitize_input()

    with {:ok, recent_items} <- fetch_recent_event_items(agent_id, room_id),
         {:ok, rag_items} <- fetch_rag_items(agent_id, query, room_id) do
      items = recent_items ++ rag_items
      context_text = render_context(items)

      {:ok,
       %{
         agent_id: agent_id,
         room_id: room_id,
         query: query,
         items: items,
         context_text: context_text,
         stats: %{
           total_items: length(items),
           total_chars: String.length(context_text),
           recent_items: length(recent_items),
           rag_items: length(rag_items)
         }
       }}
    end
  end

  @spec compact_context(Run.t(), map()) :: {:ok, map()} | {:error, term()}
  def compact_context(%Run{} = run, context) do
    max_chars = context_max_chars()
    current_chars = String.length(Map.get(context, :context_text, ""))

    if current_chars <= max_chars do
      {:ok, Map.put(context, :compaction, %{applied: false, reason: :below_threshold})}
    else
      remember_limit = remember_limit()
      query = Map.get(context, :query, "")
      items = Map.get(context, :items, [])

      remembered = select_remembered_items(items, query, remember_limit)
      forgotten = items -- remembered

      remembered_text = render_context(remembered)
      forget_summary = summarize_forgotten(forgotten)
      compacted_text = join_context_parts([remembered_text, forget_summary])

      final_text =
        if String.length(compacted_text) > max_chars do
          String.slice(compacted_text, 0, max_chars)
        else
          compacted_text
        end

      Logger.info(
        "context_compaction run_id=#{run.id} workflow_id=#{run.workflow_id} before_chars=#{current_chars} after_chars=#{String.length(final_text)} remembered=#{length(remembered)} forgotten=#{length(forgotten)}"
      )

      {:ok,
       context
       |> Map.put(:context_text, final_text)
       |> Map.put(:items, remembered)
       |> Map.put(:compaction, %{
         applied: true,
         remember_count: length(remembered),
         forget_count: length(forgotten),
         before_chars: current_chars,
         after_chars: String.length(final_text)
       })}
    end
  end

  @spec generate_response(Run.t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def generate_response(%Run{} = run, attrs, context) do
    body = attrs |> fetch_map("input") |> fetch_value("body", "") |> sanitize_input()
    agent_slug = attrs |> fetch_map("metadata") |> fetch_value("agent_slug", "automata")
    constitution_snapshot = constitution_snapshot_reference(run, attrs)

    trace_context =
      trace_context(run, attrs)
      |> Map.merge(Runtime.constitution_snapshot_metadata(constitution_snapshot))

    case Client.generate_response(
           agent_id: run.agent_id,
           agent_slug: agent_slug,
           user_input: body,
           context_text: Map.get(context, :context_text, ""),
           room_id: fetch_value(attrs, "room_id", ""),
           constitution_snapshot: constitution_snapshot,
           trace_context: trace_context
         ) do
      {:ok, text} ->
        {:ok, text}

      {:error, reason} ->
        Logger.warning(
          "workflow_activity generate_response_failed run_id=#{run.id} workflow_id=#{run.workflow_id} reason=#{inspect(reason)}"
        )

        fallback =
          if body == "" do
            "I am ready. Ask me to summarize, plan tasks, or create next steps."
          else
            "I hit a temporary model timeout. Please retry in a few seconds."
          end

        {:ok, fallback}
    end
  end

  defp trace_context(%Run{} = run, attrs) do
    input = fetch_map(attrs, "input")
    metadata = fetch_map(attrs, "metadata")
    run_metadata = Map.get(run, :metadata, %{})
    constitution_snapshot = constitution_snapshot_reference(run, attrs)

    %{
      run_id: run.id,
      mention_id: fetch_value(attrs, "mention_id") || fetch_value(input, "mention_id"),
      requested_by: fetch_value(attrs, "requested_by"),
      sender_mxid: fetch_value(input, "sender_mxid") || fetch_value(attrs, "requested_by"),
      room_id: fetch_value(attrs, "room_id", ""),
      conversation_scope:
        fetch_value(attrs, "conversation_scope") ||
          fetch_value(input, "conversation_scope") ||
          fetch_value(metadata, "conversation_scope") ||
          infer_conversation_scope(attrs),
      remote_ip:
        fetch_value(attrs, "remote_ip") ||
          fetch_value(input, "remote_ip") ||
          fetch_value(metadata, "remote_ip"),
      constitution_snapshot_id:
        fetch_value(attrs, "constitution_snapshot_id") ||
          fetch_value(run_metadata, "constitution_snapshot_id") ||
          Map.get(constitution_snapshot, :id),
      constitution_version:
        fetch_value(attrs, "constitution_version") ||
          fetch_value(run_metadata, "constitution_version") ||
          Map.get(constitution_snapshot, :version)
    }
  end

  defp infer_conversation_scope(attrs) do
    if fetch_value(attrs, "room_id", "") |> to_string() |> String.trim() != "" do
      "room"
    else
      "unknown"
    end
  end

  @spec post_response(Run.t(), map(), String.t()) :: :ok | {:error, term()}
  def post_response(%Run{} = run, attrs, response) when is_binary(response) do
    room_id = fetch_value(attrs, "room_id", "")
    plain_response = to_plain_text(response)
    reply = address_sender(plain_response, run, attrs)

    post_metadata = %{
      workflow_id: run.workflow_id,
      run_id: run.id,
      kind: "run_completion"
    }

    if String.trim(to_string(room_id)) == "" do
      :ok
    else
      case agent_post_credentials(run.agent_id) do
        %{} = credentials ->
          # Post under the agent's own Matrix account so the reply carries
          # that user's identity instead of the bot connection's.
          matrix_adapter().post_message_as(room_id, reply, credentials, post_metadata)

        nil ->
          # Fallback: no usable wallet credentials — post via the bot
          # connection with an explicit name label so readers still know
          # which agent authored the reply.
          matrix_adapter().post_message(
            room_id,
            label_agent_response(run.agent_id, reply),
            post_metadata
          )
      end
    end
  end

  @doc """
  When the triggering message addressed this agent with @, the reply is
  addressed back to the original sender with their @localpart (unless the
  reply already mentions them).
  """
  def address_sender(text, %Run{} = run, attrs) when is_binary(text) do
    if truthy?(Map.get(run.metadata || %{}, "explicitly_mentioned")) do
      case sender_localpart(attrs) do
        localpart when is_binary(localpart) and localpart != "" ->
          if mentions_localpart?(text, localpart) do
            text
          else
            "@#{localpart} #{text}"
          end

        _ ->
          text
      end
    else
      text
    end
  end

  def address_sender(text, _run, _attrs), do: text

  defp sender_localpart(attrs) do
    attrs
    |> fetch_value("requested_by", "")
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(":", parts: 2)
    |> List.first()
    |> String.downcase()
  end

  defp mentions_localpart?(text, localpart) do
    ~r/@#{Regex.escape(localpart)}(?::[a-z0-9.\-]+)?/i
    |> Regex.match?(text)
  end

  defp truthy?(value), do: value in [true, "true", "TRUE", "1", 1]

  @doc """
  Returns the Matrix credentials an agent should post under, taken from its
  active wallet, or nil when unavailable (bot fallback applies).
  """
  def agent_post_credentials(nil), do: nil

  def agent_post_credentials(agent_id) do
    case Agents.get_agent_wallet(agent_id) do
      %{status: "active", matrix_credentials: credentials} when is_map(credentials) ->
        localpart = credentials |> Map.get("localpart") |> to_string() |> String.trim()
        password = credentials |> Map.get("password") |> to_string() |> String.trim()

        if localpart != "" and password != "" do
          credentials
        else
          nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Prefixes a posted response with the responding agent's name (and title) so
  room readers can tell which office member replied. Leaves the text untouched
  when no agent profile is available.
  """
  def label_agent_response(nil, text), do: text

  def label_agent_response(agent_id, text) when is_binary(text) do
    case Agents.get_agent(agent_id) do
      %{display_name: display_name, metadata: metadata} ->
        name = presence(display_name)
        title = metadata |> Map.get("title") |> to_string() |> String.trim()

        prefix =
          cond do
            name != nil and title != "" -> "#{name} (#{title})"
            name != nil -> name
            true -> ""
          end

        if prefix == "", do: text, else: "#{prefix}: #{text}"

      _ ->
        text
    end
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil

  @spec persist_memory(Run.t(), map(), map(), String.t()) :: :ok
  def persist_memory(%Run{} = run, attrs, context, response) do
    body = attrs |> fetch_map("input") |> fetch_value("body", "") |> sanitize_input()
    plain_response = to_plain_text(response)

    memory_content =
      join_context_parts([
        "User message:\n#{body}",
        "Agent response:\n#{plain_response}",
        "Context snapshot:\n#{Map.get(context, :context_text, "")}"
      ])

    # Room-thread memory: this entry belongs to the agent's thread in this
    # specific room and is only retrieved when the agent works in that room.
    _ =
      MemoryStore.ingest(run.agent_id, memory_content,
        source: "workflow_turn",
        metadata: %{
          run_id: run.id,
          workflow_id: run.workflow_id,
          room_id: fetch_value(attrs, "room_id", ""),
          scope: "room",
          context_compaction: Map.get(context, :compaction, %{})
        }
      )

    :ok
  end

  @doc """
  Extracts durable personal facts from a completed exchange and stores them
  in the agent's main personal memory — the cross-room memory level that
  travels with the agent between rooms.

  Gate-able via AUTOMATA_PERSONAL_MEMORY_ENABLED.
  """
  @spec consolidate_personal_memory(Run.t(), map(), String.t()) :: :ok
  def consolidate_personal_memory(%Run{} = run, attrs, response) do
    if personal_memory_enabled?() and String.trim(to_string(response)) != "" do
      opts =
        personal_facts_client_opts(run, attrs, response)
        |> Keyword.put(:tool_results, Map.get(attrs, "tool_context", []))

      facts =
        case Client.extract_personal_facts(opts) do
          %{"facts" => facts} when is_list(facts) -> facts
          _ -> []
        end

      facts
      |> Enum.take(3)
      |> Enum.each(fn fact ->
        content = fact |> to_string() |> String.trim()

        if content != "" and not MemoryStore.personal_memory_exists?(run.agent_id, content) do
          _ =
            MemoryStore.ingest(run.agent_id, content,
              source: "personal_consolidation",
              metadata: %{
                run_id: run.id,
                scope: "personal",
                room_id: fetch_value(attrs, "room_id", "")
              }
            )
        end
      end)
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "personal_memory_consolidation_failed run_id=#{run.id} reason=#{Exception.message(error)}"
      )

      :ok
  end

  defp personal_facts_client_opts(%Run{} = run, attrs, response) do
    input = fetch_map(attrs, "input")
    metadata = fetch_map(attrs, "metadata")
    room_id = fetch_value(attrs, "room_id", "")

    [
      agent_id: run.agent_id,
      agent_slug: fetch_value(metadata, "agent_slug", "automata"),
      user_input: fetch_value(input, "body", ""),
      last_response: to_plain_text(response),
      context_text: "",
      room_id: room_id,
      trace_context: %{
        run_id: run.id,
        room_id: room_id,
        requested_by: fetch_value(attrs, "requested_by"),
        remote_ip: fetch_value(attrs, "remote_ip"),
        conversation_scope: fetch_value(attrs, "conversation_scope")
      }
    ]
  end

  defp personal_memory_enabled? do
    System.get_env("AUTOMATA_PERSONAL_MEMORY_ENABLED", "true") in [
      "1",
      "true",
      "TRUE",
      "yes",
      "YES"
    ]
  end

  defp fetch_recent_event_items(nil, _room_id), do: {:ok, []}

  # Recent room history for context: every agent working in a room sees the
  # room's message stream — including messages that were addressed to other
  # members (which this agent did not run for) — so each agent understands
  # the full context when it is dispatched.
  defp fetch_recent_event_items(_agent_id, room_id) do
    limit = recent_event_limit()

    rows =
      from(m in Mention,
        where: m.room_id == ^to_string(room_id),
        order_by: [desc: m.inserted_at],
        limit: ^limit,
        select: %{
          mention_id: m.id,
          body: m.body,
          sender_mxid: m.sender_mxid,
          inserted_at: m.inserted_at
        }
      )
      |> Repo.all()

    items =
      Enum.map(rows, fn row ->
        %{
          type: :recent_event,
          timestamp: row.inserted_at,
          text: "[#{row.sender_mxid}] #{to_string(row.body)}",
          score: 0.0
        }
      end)

    {:ok, items}
  rescue
    _ -> {:ok, []}
  end

  defp fetch_rag_items(nil, _query, _room_id), do: {:ok, []}
  defp fetch_rag_items(_agent_id, "", _room_id), do: {:ok, []}

  defp fetch_rag_items(agent_id, query, room_id) do
    with {:ok, rag} <- RAG.retrieve(agent_id, query, top_k: rag_top_k(), room_id: room_id) do
      items =
        rag.contexts
        |> Enum.map(fn ctx ->
          level = ctx.metadata |> Map.get("memory_level", "memory")

          type =
            case level do
              "personal" -> :personal_memory
              "room" -> :room_memory
              _ -> :rag_memory
            end

          %{
            type: type,
            timestamp: Map.get(ctx, :inserted_at),
            text: Map.get(ctx, :content, ""),
            score: Map.get(ctx, :score, 0.0)
          }
        end)

      {:ok, items}
    else
      _ -> {:ok, []}
    end
  end

  defp select_remembered_items(items, query, remember_limit) do
    query_tokens = tokenize(query)

    items
    |> Enum.map(fn item ->
      text = Map.get(item, :text, "")
      relevance = token_overlap_score(query_tokens, tokenize(text))
      recency = recency_score(Map.get(item, :timestamp))
      rag_score = Map.get(item, :score, 0.0)
      final_score = relevance * 2.0 + recency * 0.7 + rag_score
      {item, final_score}
    end)
    |> Enum.sort_by(fn {_item, score} -> score end, :desc)
    |> Enum.take(remember_limit)
    |> Enum.map(fn {item, _score} -> item end)
  end

  defp summarize_forgotten([]), do: ""

  defp summarize_forgotten(forgotten) do
    recent_count = Enum.count(forgotten, &(&1.type == :recent_event))
    rag_count = Enum.count(forgotten, &(&1.type == :rag_memory))

    "FORGET STEP SUMMARY: Omitted #{length(forgotten)} lower-signal context entries " <>
      "(recent events: #{recent_count}, rag memories: #{rag_count}) to reduce noise."
  end

  defp render_context([]), do: ""

  defp render_context(items) do
    items
    |> Enum.map_join("\n\n", fn item ->
      prefix =
        case item.type do
          :recent_event -> "RECENT EVENT"
          :rag_memory -> "RAG MEMORY"
          :room_memory -> "ROOM MEMORY"
          :personal_memory -> "PERSONAL MEMORY"
          _ -> "CONTEXT"
        end

      "#{prefix}: #{String.trim(to_string(item.text))}"
    end)
  end

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp sanitize_input(input) do
    input
    |> to_string()
    |> String.trim()
    |> String.replace(~r/^@?[a-z0-9._\-]+[:\s-]*/i, "")
  end

  defp join_context_parts(parts) do
    parts
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp to_plain_text(text) when is_binary(text) do
    text
    |> strip_tool_call_json()
    |> truncate_tool_artifacts()
    |> String.replace(~r/```[\s\S]*?```/u, "")
    |> String.replace(~r/`([^`]*)`/u, "\\1")
    |> String.replace(~r/\*\*([^*]+)\*\*/u, "\\1")
    |> String.replace(~r/\*([^*]+)\*/u, "\\1")
    |> String.replace(~r/^\#{1,6}\s+/um, "")
    |> String.replace(~r/^\s*[-*+]\s+/um, "")
    |> String.replace(~r/^\s*\d+\.\s+/um, "")
    |> String.replace(~r/\[([^\]]+)\]\(([^)]+)\)/u, "\\1 (\\2)")
    |> String.replace(~r/<[^>]+>/u, "")
    |> String.replace(~r/\n{3,}/u, "\n\n")
    |> String.trim()
  end

  # Strips accidental tool-call JSON the model echoed into its reply text.
  @tool_artifact_prefixes [
    "{\"tool_results\"",
    "{\"tool\"",
    "{\"tool_call\"",
    "{\"send_matrix_message\"",
    "{\"name\": \"send_matrix_message\""
  ]

  # Hard guard: a reply that is ONLY a tool-call envelope (JSON with "tool"
  # and "arguments") must never be posted to a room — the loop executes tools,
  # the chat gets plain text. Replace with a neutral acknowledgment.
  defp strip_tool_call_json(text) when is_binary(text) do
    case Jason.decode(String.trim(text)) do
      {:ok, %{"tool" => _, "arguments" => _}} -> "I\'ll take care of that for you."
      {:ok, %{"tool_calls" => _}} -> "I\'ll take care of that for you."
      _ -> text
    end
  rescue
    _ -> text
  end

  defp truncate_tool_artifacts(text) do
    Enum.reduce(@tool_artifact_prefixes, text, fn prefix, acc ->
      case :binary.match(acc, prefix) do
        {index, _length} -> binary_part(acc, 0, index)
        :nomatch -> acc
      end
    end)
    |> String.trim()
  end

  defp constitution_snapshot_reference(%Run{} = run, attrs) do
    %{
      "constitution_snapshot_id" => fetch_value(attrs, "constitution_snapshot_id"),
      "constitution_version" => fetch_value(attrs, "constitution_version")
    }
    |> Map.merge(
      Map.take(Map.get(run, :metadata, %{}), ["constitution_snapshot_id", "constitution_version"])
    )
    |> Runtime.constitution_snapshot_reference()
  end

  defp tokenize(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
  end

  defp token_overlap_score([], _), do: 0.0

  defp token_overlap_score(query_tokens, text_tokens) do
    query_set = MapSet.new(query_tokens)
    text_set = MapSet.new(text_tokens)
    overlap = MapSet.intersection(query_set, text_set) |> MapSet.size()
    overlap / max(length(query_tokens), 1)
  end

  defp recency_score(nil), do: 0.0

  defp recency_score(%DateTime{} = inserted_at) do
    hours = DateTime.diff(DateTime.utc_now(), inserted_at, :second) / 3600.0
    1.0 / (1.0 + max(hours, 0.0))
  end

  defp recency_score(_), do: 0.0

  defp context_max_chars do
    System.get_env("AUTOMATA_CONTEXT_MAX_CHARS", "7000")
    |> String.to_integer()
  rescue
    _ -> 7000
  end

  defp remember_limit do
    System.get_env("AUTOMATA_CONTEXT_REMEMBER_ITEMS", "8")
    |> String.to_integer()
  rescue
    _ -> 8
  end

  defp recent_event_limit do
    System.get_env("AUTOMATA_CONTEXT_RECENT_EVENTS", "10")
    |> String.to_integer()
  rescue
    _ -> 10
  end

  defp rag_top_k do
    System.get_env("AUTOMATA_CONTEXT_RAG_TOP_K", "6")
    |> String.to_integer()
  rescue
    _ -> 6
  end

  defp fetch_map(map, key) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp fetch_value(map, key, default \\ nil) when is_map(map) do
    atom_key =
      case key do
        "agent_id" -> :agent_id
        "input" -> :input
        "body" -> :body
        "metadata" -> :metadata
        "agent_slug" -> :agent_slug
        "room_id" -> :room_id
        "mention_id" -> :mention_id
        "requested_by" -> :requested_by
        "sender_mxid" -> :sender_mxid
        "conversation_scope" -> :conversation_scope
        "remote_ip" -> :remote_ip
        "constitution_snapshot_id" -> :constitution_snapshot_id
        "constitution_version" -> :constitution_version
        _ -> nil
      end

    Map.get(map, key, atom_key && Map.get(map, atom_key, default)) || default
  end
end
