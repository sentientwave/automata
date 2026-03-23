defmodule SentientwaveAutomata.Agents.WorkflowActivities do
  @moduledoc """
  Temporal activity entrypoint for agent run execution steps.
  """

  use TemporalSdk.Activity

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Activities
  alias SentientwaveAutomata.Agents.DeepResearch
  alias SentientwaveAutomata.Agents.LLM.Client
  alias SentientwaveAutomata.Agents.Run
  alias SentientwaveAutomata.Agents.Tools.Executor
  alias SentientwaveAutomata.Temporal
  require Logger

  @impl true
  def execute(_context, [%{"step" => "build_context", "run_id" => run_id, "attrs" => attrs}]) do
    run = fetch_run!(run_id)
    [unwrap_result!(Activities.build_context(run, attrs), "build agent context")]
  end

  def execute(_context, [%{"step" => "compact_context", "run_id" => run_id, "context" => context}]) do
    run = fetch_run!(run_id)
    [unwrap_result!(Activities.compact_context(run, context), "compact agent context")]
  end

  def execute(
        _context,
        [
          %{
            "step" => "assess_deep_research",
            "run_id" => run_id,
            "attrs" => attrs,
            "context" => workflow_context
          }
        ]
      ) do
    run = fetch_run!(run_id)

    with_typing_lease(run, attrs, fn ->
      [Client.deep_research_decision(research_client_opts(run, attrs, workflow_context))]
    end)
  end

  def execute(
        _context,
        [
          %{
            "step" => "plan_tool_calls",
            "run_id" => run_id,
            "attrs" => attrs,
            "context" => workflow_context
          }
        ]
      ) do
    run = fetch_run!(run_id)

    with_typing_lease(run, attrs, fn ->
      [
        Client.plan_tool_calls(tool_client_opts(run, attrs, workflow_context))
        |> unwrap_result!("plan tool calls")
        |> then(fn plan -> Map.get(plan, :tool_calls) || Map.get(plan, "tool_calls") || [] end)
      ]
    end)
  end

  def execute(_context, [
        %{"step" => "execute_tool_calls", "run_id" => run_id, "tool_calls" => tool_calls}
      ]) do
    run = fetch_run!(run_id)
    [unwrap_result!(Client.execute_tool_calls(run.agent_id, tool_calls), "execute tool calls")]
  end

  def execute(
        _context,
        [
          %{
            "step" => "synthesize_response",
            "run_id" => run_id,
            "attrs" => attrs,
            "context" => workflow_context,
            "tool_context" => tool_context
          }
        ]
      ) do
    run = fetch_run!(run_id)

    with_typing_lease(run, attrs, fn ->
      [
        Client.synthesize_tool_response(
          tool_client_opts(run, attrs, workflow_context),
          tool_context
        )
        |> unwrap_result!("synthesize tool response")
      ]
    end)
  end

  def execute(
        _context,
        [
          %{
            "step" => "generate_response_without_tools",
            "run_id" => run_id,
            "attrs" => attrs,
            "context" => workflow_context
          }
        ]
      ) do
    run = fetch_run!(run_id)

    with_typing_lease(run, attrs, fn ->
      [
        Client.generate_response_without_tools(tool_client_opts(run, attrs, workflow_context))
        |> unwrap_result!("generate agent response")
      ]
    end)
  end

  def execute(
        _context,
        [
          %{
            "step" => "run_deep_research_round",
            "run_id" => run_id,
            "attrs" => attrs,
            "context" => workflow_context,
            "round_index" => round_index,
            "max_rounds" => max_rounds,
            "queries" => queries,
            "prior_summary" => prior_summary
          }
        ]
      ) do
    run = fetch_run!(run_id)

    with_typing_lease(run, attrs, fn ->
      [
        perform_deep_research_round(
          run,
          attrs,
          workflow_context,
          normalize_positive_integer(round_index, 1),
          normalize_positive_integer(max_rounds, 1),
          normalize_queries(queries),
          normalize_text(prior_summary)
        )
      ]
    end)
  end

  def execute(
        _context,
        [
          %{
            "step" => "synthesize_deep_research_response",
            "run_id" => run_id,
            "attrs" => attrs,
            "context" => workflow_context,
            "research" => research
          }
        ]
      ) do
    run = fetch_run!(run_id)

    with_typing_lease(run, attrs, fn ->
      response =
        case Client.synthesize_deep_research_response(
               research_client_opts(run, attrs, workflow_context),
               research
             ) do
          {:ok, text} ->
            text

          {:error, reason} ->
            Logger.warning(
              "deep_research_synthesis_failed run_id=#{run.id} workflow_id=#{run.workflow_id} reason=#{inspect(reason)}"
            )

            fallback_research_response(research)
        end

      [response]
    end)
  end

  def execute(
        _context,
        [
          %{
            "step" => "post_response",
            "run_id" => run_id,
            "attrs" => attrs,
            "response" => response
          }
        ]
      ) do
    run = fetch_run!(run_id)

    :ok =
      unwrap_result!(Activities.post_response(run, attrs, response), "post response to Matrix")

    [%{"posted" => true}]
  end

  def execute(
        _context,
        [
          %{
            "step" => "persist_memory",
            "run_id" => run_id,
            "attrs" => attrs,
            "context" => workflow_context,
            "response" => response
          }
        ]
      ) do
    run = fetch_run!(run_id)
    :ok = Activities.persist_memory(run, attrs, workflow_context, response)
    [%{"persisted" => true}]
  end

  def execute(
        _context,
        [
          %{
            "step" => "mark_run_status",
            "run_id" => run_id,
            "status" => status,
            "updates" => updates
          }
        ]
      ) do
    run = fetch_run!(run_id)

    updated_run =
      unwrap_result!(Agents.update_run(run, Map.put(updates, :status, status)), "update run")

    [%{"run_id" => updated_run.id, "status" => Atom.to_string(updated_run.status)}]
  end

  def execute(_context, [
        %{
          "step" => "set_typing",
          "room_id" => room_id,
          "typing" => typing,
          "metadata" => metadata
        }
      ]) do
    case set_typing(room_id, typing, metadata) do
      :ok -> [%{"typing" => typing}]
      {:error, reason} -> raise "failed to update typing state: #{inspect(reason)}"
    end
  end

  def execute(context, [%{} = payload]) do
    normalized_payload = Temporal.stringify_keys(payload)

    if normalized_payload == payload do
      fail_non_retryable(
        "agent.workflow.unsupported_step",
        "unsupported agent workflow activity step: #{inspect(payload)}"
      )
    else
      execute(context, [normalized_payload])
    end
  end

  def execute(_context, [payload]) do
    fail_non_retryable(
      "agent.workflow.unsupported_step",
      "unsupported agent workflow activity step: #{inspect(payload)}"
    )
  end

  defp tool_client_opts(%Run{} = run, attrs, workflow_context) do
    input = fetch_map(attrs, "input")
    metadata = fetch_map(attrs, "metadata")

    [
      agent_id: run.agent_id,
      agent_slug: fetch_value(metadata, "agent_slug", "automata"),
      user_input: fetch_value(input, "body", ""),
      context_text: fetch_value(workflow_context, "context_text", ""),
      room_id: fetch_value(attrs, "room_id", ""),
      constitution_snapshot:
        Map.get(run.metadata || %{}, "constitution_snapshot_id") &&
          %{
            id: Map.get(run.metadata || %{}, "constitution_snapshot_id"),
            version: Map.get(run.metadata || %{}, "constitution_version")
          },
      trace_context: %{
        run_id: run.id,
        room_id: fetch_value(attrs, "room_id", ""),
        requested_by: fetch_value(attrs, "requested_by"),
        remote_ip: fetch_value(attrs, "remote_ip"),
        conversation_scope: fetch_value(attrs, "conversation_scope")
      }
    ]
  end

  defp research_client_opts(%Run{} = run, attrs, workflow_context, extra_trace \\ %{}) do
    base = tool_client_opts(run, attrs, workflow_context)
    trace_context = Keyword.get(base, :trace_context, %{})

    base
    |> Keyword.put(:deep_research, true)
    |> Keyword.put(
      :trace_context,
      Map.merge(trace_context, Map.merge(%{"research_mode" => "deep_research"}, extra_trace))
    )
  end

  defp perform_deep_research_round(
         %Run{} = run,
         attrs,
         workflow_context,
         round_index,
         max_rounds,
         queries,
         prior_summary
       ) do
    available_tools = Executor.available_tools(run.agent_id)
    normalized_queries = normalize_queries(queries)

    if normalized_queries == [] do
      empty_research_round(round_index, "No research queries were available for this round.")
    else
      tool_args = build_brave_search_args(normalized_queries)

      case Executor.execute("brave_search", tool_args, available_tools) do
        {:ok, search_result} ->
          evidence = extract_round_evidence(search_result)

          review =
            Client.review_deep_research_round(
              research_client_opts(run, attrs, workflow_context, %{
                "research_round" => round_index
              }),
              %{
                "evidence" => evidence,
                "prior_summary" => prior_summary,
                "round_index" => round_index,
                "max_rounds" => max_rounds
              }
            )
            |> unwrap_result!("review deep research round")

          %{
            "round" => round_index,
            "queries" => normalized_queries,
            "search_count" =>
              normalize_positive_integer(Map.get(search_result, "search_count"), 1),
            "evidence_count" => count_sources(evidence),
            "evidence" => evidence,
            "sources" => Map.get(review, "top_sources", []),
            "key_findings" => Map.get(review, "key_findings", []),
            "round_summary" => Map.get(review, "round_summary", ""),
            "continue_research" => Map.get(review, "continue_research", false),
            "follow_up_queries" => Map.get(review, "follow_up_queries", [])
          }

        {:error, reason} ->
          empty_research_round(
            round_index,
            "Deep research search failed in this round: #{inspect(reason)}"
          )
      end
    end
  end

  defp build_brave_search_args([query | rest]) do
    %{
      "query" => query,
      "queries" => rest,
      "count" => DeepResearch.config()["results_per_query"]
    }
  end

  defp extract_round_evidence(search_result) when is_map(search_result) do
    searches =
      case Map.get(search_result, "searches") do
        searches when is_list(searches) -> searches
        _ -> []
      end

    searches
    |> Enum.filter(&(&1["status"] == "ok"))
    |> Enum.map(fn search ->
      sources =
        search
        |> Map.get("evidence", [])
        |> List.wrap()
        |> Enum.map(&normalize_source/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(4)

      findings =
        sources
        |> Enum.map(fn source ->
          title = Map.get(source, "title", "Untitled")
          summary = Map.get(source, "summary", "")
          if(summary == "", do: title, else: "#{title}: #{summary}")
        end)
        |> Enum.take(4)

      %{
        "query" => Map.get(search, "query", ""),
        "findings" => findings,
        "sources" => sources
      }
    end)
    |> Enum.reject(fn entry -> entry["query"] == "" and entry["sources"] == [] end)
  end

  defp extract_round_evidence(_search_result), do: []

  defp normalize_source(%{} = source) do
    title = normalize_text(Map.get(source, "title", "Untitled"))
    url = normalize_text(Map.get(source, "url", ""))
    summary = normalize_text(Map.get(source, "description", ""))

    if url == "" do
      nil
    else
      %{
        "title" => if(title == "", do: "Untitled", else: title),
        "url" => url,
        "summary" => truncate_text(summary, 280)
      }
    end
  end

  defp normalize_source(_source), do: nil

  defp count_sources(evidence) when is_list(evidence) do
    evidence
    |> Enum.flat_map(&Map.get(&1, "sources", []))
    |> Enum.uniq_by(&Map.get(&1, "url"))
    |> length()
  end

  defp count_sources(_evidence), do: 0

  defp empty_research_round(round_index, summary) do
    %{
      "round" => round_index,
      "queries" => [],
      "search_count" => 0,
      "evidence_count" => 0,
      "evidence" => [],
      "sources" => [],
      "key_findings" => [],
      "round_summary" => summary,
      "continue_research" => false,
      "follow_up_queries" => []
    }
  end

  defp fallback_research_response(research) when is_map(research) do
    summary = normalize_text(Map.get(research, "summary", ""))
    sources = Map.get(research, "sources", [])

    case {summary, sources} do
      {"", []} ->
        "I completed a research pass, but I could not synthesize a stronger answer from the gathered evidence."

      _ ->
        source_text =
          sources
          |> Enum.map(fn source ->
            title = Map.get(source, "title", "Untitled")
            url = Map.get(source, "url", "")
            if(url == "", do: title, else: "#{title} (#{url})")
          end)
          |> Enum.take(3)
          |> Enum.join("; ")

        [
          if(summary == "", do: nil, else: summary),
          if(source_text == "", do: nil, else: "Key sources: #{source_text}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
    end
  end

  defp fetch_run!(run_id) when is_binary(run_id) do
    case Agents.get_run(run_id) do
      %Run{} = run -> run
      nil -> fail_non_retryable("agent.run.not_found", "run not found: #{run_id}")
    end
  end

  defp fetch_run!(_run_id), do: fail_non_retryable("agent.run.not_found", "run not found")

  defp with_typing_lease(%Run{} = run, attrs, fun) when is_function(fun, 0) do
    room_id = fetch_value(attrs, "room_id", "")
    metadata = %{run_id: run.id, workflow_id: run.workflow_id}

    heartbeat_pid =
      if is_binary(room_id) and String.trim(room_id) != "" do
        start_typing_heartbeat(room_id, metadata)
      else
        nil
      end

    try do
      fun.()
    after
      stop_typing_heartbeat(heartbeat_pid)
      _ = set_typing(room_id, false, metadata)
    end
  end

  defp start_typing_heartbeat(room_id, metadata) do
    parent = self()

    spawn_link(fn ->
      typing_loop(parent, room_id, metadata, typing_interval_ms())
    end)
  end

  defp stop_typing_heartbeat(nil), do: :ok

  defp stop_typing_heartbeat(pid) when is_pid(pid) do
    ref = make_ref()
    send(pid, {:stop, self(), ref})

    receive do
      {:stopped, ^ref} -> :ok
    after
      500 -> :ok
    end
  end

  defp typing_loop(parent, room_id, metadata, interval_ms) do
    _ = set_typing(room_id, true, metadata)

    receive do
      {:stop, caller, ref} ->
        send(caller, {:stopped, ref})
        :ok
    after
      interval_ms ->
        if Process.alive?(parent) do
          typing_loop(parent, room_id, metadata, interval_ms)
        else
          :ok
        end
    end
  end

  defp set_typing(room_id, typing, metadata) when is_binary(room_id) and room_id != "" do
    matrix_adapter().set_typing(room_id, typing, typing_timeout_ms(), metadata)
  end

  defp set_typing(_room_id, _typing, _metadata), do: :ok

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp typing_interval_ms do
    max(div(typing_timeout_ms(), 2), 1_000)
  end

  defp typing_timeout_ms do
    System.get_env("MATRIX_TYPING_TIMEOUT_MS", "12000")
    |> String.to_integer()
  rescue
    _ -> 12_000
  end

  defp unwrap_result!({:ok, result}, _action), do: result

  defp unwrap_result!({:error, reason}, action) do
    raise "#{action} failed: #{inspect(reason)}"
  end

  defp unwrap_result!(result, _action), do: result

  defp fail_non_retryable(type, message) do
    fail(message: message, type: type, non_retryable: true)
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
        "input" -> :input
        "metadata" -> :metadata
        "agent_slug" -> :agent_slug
        "body" -> :body
        "context_text" -> :context_text
        "room_id" -> :room_id
        "requested_by" -> :requested_by
        "remote_ip" -> :remote_ip
        "conversation_scope" -> :conversation_scope
        _ -> nil
      end

    Map.get(map, key, atom_key && Map.get(map, atom_key, default)) || default
  end

  defp normalize_queries(queries) when is_list(queries) do
    queries
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.take(DeepResearch.config()["max_queries_per_round"])
  end

  defp normalize_queries(_queries), do: []

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) do
    case Integer.parse(to_string(value || "")) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.trim()
  end

  defp truncate_text(text, limit) when is_binary(text) do
    if String.length(text) > limit do
      String.slice(text, 0, limit)
    else
      text
    end
  end
end
