defmodule SentientwaveAutomata.Agents.Activities do
  @moduledoc """
  Agent workflow activities.

  Activities are side-effecting steps suitable for execution by Temporal workers.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents.LLM.Client
  alias SentientwaveAutomata.Agents.MemoryStore
  alias SentientwaveAutomata.Agents.Mention
  alias SentientwaveAutomata.Agents.RAG
  alias SentientwaveAutomata.Agents.Run
  alias SentientwaveAutomata.Repo
  require Logger

  @spec build_context(Run.t(), map()) :: {:ok, map()} | {:error, term()}
  def build_context(%Run{} = run, attrs) do
    agent_id = run.agent_id || Map.get(attrs, :agent_id)
    query = attrs |> Map.get(:input, %{}) |> Map.get(:body, "") |> sanitize_input()

    with {:ok, recent_items} <- fetch_recent_event_items(agent_id),
         {:ok, rag_items} <- fetch_rag_items(agent_id, query) do
      items = recent_items ++ rag_items
      context_text = render_context(items)

      {:ok,
       %{
         agent_id: agent_id,
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
    body = attrs |> Map.get(:input, %{}) |> Map.get(:body, "") |> sanitize_input()
    agent_slug = attrs |> Map.get(:metadata, %{}) |> Map.get(:agent_slug, "automata")

    case Client.generate_response(
           agent_id: run.agent_id,
           agent_slug: agent_slug,
           user_input: body,
           context_text: Map.get(context, :context_text, ""),
           room_id: Map.get(attrs, :room_id, ""),
           trace_context: trace_context(run, attrs)
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
    input = Map.get(attrs, :input, %{})
    metadata = Map.get(attrs, :metadata, %{})

    %{
      run_id: run.id,
      mention_id: Map.get(attrs, :mention_id) || Map.get(input, :mention_id),
      requested_by: Map.get(attrs, :requested_by),
      sender_mxid: Map.get(input, :sender_mxid) || Map.get(attrs, :requested_by),
      room_id: Map.get(attrs, :room_id, ""),
      conversation_scope:
        Map.get(attrs, :conversation_scope) ||
          Map.get(input, :conversation_scope) ||
          Map.get(metadata, "conversation_scope") ||
          Map.get(metadata, :conversation_scope) ||
          infer_conversation_scope(attrs),
      remote_ip:
        Map.get(attrs, :remote_ip) ||
          Map.get(input, :remote_ip) ||
          Map.get(metadata, "remote_ip") ||
          Map.get(metadata, :remote_ip)
    }
  end

  defp infer_conversation_scope(attrs) do
    if Map.get(attrs, :room_id, "") |> to_string() |> String.trim() != "" do
      "room"
    else
      "unknown"
    end
  end

  @spec post_response(Run.t(), map(), String.t()) :: :ok | {:error, term()}
  def post_response(%Run{} = run, attrs, response) when is_binary(response) do
    room_id = Map.get(attrs, :room_id, "")
    plain_response = to_plain_text(response)

    matrix_adapter().post_message(room_id, plain_response, %{
      workflow_id: run.workflow_id,
      run_id: run.id,
      kind: "run_completion"
    })
  end

  @spec persist_memory(Run.t(), map(), map(), String.t()) :: :ok
  def persist_memory(%Run{} = run, attrs, context, response) do
    body = attrs |> Map.get(:input, %{}) |> Map.get(:body, "") |> sanitize_input()
    plain_response = to_plain_text(response)

    memory_content =
      join_context_parts([
        "User message:\n#{body}",
        "Agent response:\n#{plain_response}",
        "Context snapshot:\n#{Map.get(context, :context_text, "")}"
      ])

    _ =
      MemoryStore.ingest(run.agent_id, memory_content,
        source: "workflow_turn",
        metadata: %{
          run_id: run.id,
          workflow_id: run.workflow_id,
          context_compaction: Map.get(context, :compaction, %{})
        }
      )

    :ok
  end

  defp fetch_recent_event_items(nil), do: {:ok, []}

  defp fetch_recent_event_items(agent_id) do
    limit = recent_event_limit()

    rows =
      Repo.all(
        from r in Run,
          join: m in Mention,
          on: m.id == r.mention_id,
          where: r.agent_id == ^agent_id,
          order_by: [desc: r.inserted_at],
          limit: ^limit,
          select: %{
            mention_id: m.id,
            body: m.body,
            sender_mxid: m.sender_mxid,
            inserted_at: m.inserted_at
          }
      )

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

  defp fetch_rag_items(nil, _query), do: {:ok, []}
  defp fetch_rag_items(_agent_id, ""), do: {:ok, []}

  defp fetch_rag_items(agent_id, query) do
    with {:ok, rag} <- RAG.retrieve(agent_id, query, top_k: rag_top_k()) do
      items =
        rag.contexts
        |> Enum.map(fn ctx ->
          %{
            type: :rag_memory,
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
end
