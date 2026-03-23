defmodule SentientwaveAutomata.Agents.Workflow do
  @moduledoc """
  Temporal-owned agent run workflow.
  """

  use TemporalSdk.Workflow

  alias SentientwaveAutomata.Temporal

  @activity SentientwaveAutomata.Agents.WorkflowActivities

  @impl true
  def execute(_context, [%{"run_id" => run_id, "attrs" => attrs}]) do
    _ =
      activity("mark_run_status", %{
        run_id: run_id,
        status: :running,
        updates: %{error: %{}, result: %{}}
      })

    _ =
      typing_activity(
        fetch_attr(attrs, "room_id", ""),
        true,
        run_id,
        fetch_attr(attrs, "workflow_id")
      )

    workflow_context = activity("build_context", %{run_id: run_id, attrs: attrs})
    compacted_context = activity("compact_context", %{run_id: run_id, context: workflow_context})

    research_decision =
      activity("assess_deep_research", %{run_id: run_id, attrs: attrs, context: compacted_context})

    {response, research_result} =
      if deep_research_enabled?(research_decision) do
        research_result =
          run_deep_research(run_id, attrs, compacted_context, research_decision)

        response =
          activity("synthesize_deep_research_response", %{
            run_id: run_id,
            attrs: attrs,
            context: compacted_context,
            research: research_result
          })

        {response, research_result}
      else
        tool_calls =
          activity("plan_tool_calls", %{run_id: run_id, attrs: attrs, context: compacted_context})

        response =
          case tool_calls do
            [] ->
              activity("generate_response_without_tools", %{
                run_id: run_id,
                attrs: attrs,
                context: compacted_context
              })

            _ ->
              tool_context =
                activity("execute_tool_calls", %{run_id: run_id, tool_calls: tool_calls})

              activity("synthesize_response", %{
                run_id: run_id,
                attrs: attrs,
                context: compacted_context,
                tool_context: tool_context
              })
          end

        {response, nil}
      end

    _ = activity("post_response", %{run_id: run_id, attrs: attrs, response: response})

    memory_context = attach_research_context(compacted_context, research_result)

    _ =
      activity("persist_memory", %{
        run_id: run_id,
        attrs: attrs,
        context: memory_context,
        response: response
      })

    _ =
      activity("mark_run_status", %{
        run_id: run_id,
        status: :succeeded,
        updates: %{
          result: %{
            response: response,
            context: %{
              total_items: get_in(compacted_context, [:stats, :total_items]),
              total_chars: get_in(compacted_context, [:stats, :total_chars]),
              compaction: Map.get(compacted_context, :compaction, %{})
            },
            research: research_result || %{"mode" => "standard"}
          },
          error: %{}
        }
      })

    _ =
      typing_activity(
        fetch_attr(attrs, "room_id", ""),
        false,
        run_id,
        fetch_attr(attrs, "workflow_id")
      )

    %{response: response, context: compacted_context}
  rescue
    error ->
      reason = Exception.message(error)

      _ =
        activity("mark_run_status", %{
          run_id: run_id,
          status: :failed,
          updates: %{error: %{reason: reason}}
        })

      _ =
        typing_activity(
          fetch_attr(attrs, "room_id", ""),
          false,
          run_id,
          fetch_attr(attrs, "workflow_id")
        )

      fail_workflow_execution(%{message: reason})
  end

  defp activity(step, payload) do
    [%{result: result}] =
      wait_all([
        start_activity(
          @activity,
          [Temporal.activity_payload(step, payload)],
          task_queue: Temporal.activity_task_queue(),
          start_to_close_timeout: {15, :minute}
        )
      ])

    unwrap_activity_result(result)
  end

  defp unwrap_activity_result([result]), do: result
  defp unwrap_activity_result({:ok, [result]}), do: result
  defp unwrap_activity_result({:ok, result}), do: result
  defp unwrap_activity_result(result), do: result

  defp run_deep_research(run_id, attrs, context, decision) do
    max_rounds = normalize_positive_integer(fetch_result(decision, "max_rounds"), 1)
    initial_queries = normalize_queries(fetch_result(decision, "queries"))

    initial_state = %{
      "mode" => "deep_research",
      "requested_by_user" => fetch_result(decision, "requested_by_user") == true,
      "reason" => fetch_result(decision, "reason") || "deep_research",
      "rounds" => [],
      "summary" => "",
      "sources" => [],
      "queries_executed" => []
    }

    do_run_deep_research(run_id, attrs, context, initial_state, initial_queries, 1, max_rounds)
  end

  defp do_run_deep_research(_run_id, _attrs, _context, state, [], _round_index, _max_rounds),
    do: state

  defp do_run_deep_research(run_id, attrs, context, state, queries, round_index, max_rounds)
       when round_index <= max_rounds do
    round_result =
      activity("run_deep_research_round", %{
        run_id: run_id,
        attrs: attrs,
        context: context,
        round_index: round_index,
        max_rounds: max_rounds,
        queries: queries,
        prior_summary: Map.get(state, "summary", "")
      })

    updated_state = merge_research_state(state, round_result, queries)
    continue? = fetch_result(round_result, "continue_research") == true
    follow_up_queries = normalize_queries(fetch_result(round_result, "follow_up_queries"))

    if continue? and follow_up_queries != [] and round_index < max_rounds do
      do_run_deep_research(
        run_id,
        attrs,
        context,
        updated_state,
        follow_up_queries,
        round_index + 1,
        max_rounds
      )
    else
      updated_state
    end
  end

  defp do_run_deep_research(
         _run_id,
         _attrs,
         _context,
         state,
         _queries,
         _round_index,
         _max_rounds
       ),
       do: state

  defp merge_research_state(state, round_result, queries) do
    rounds = Map.get(state, "rounds", []) ++ [round_result]
    summary = fetch_result(round_result, "round_summary") || Map.get(state, "summary", "")

    sources =
      (Map.get(state, "sources", []) ++
         normalize_source_list(fetch_result(round_result, "sources")))
      |> Enum.uniq_by(&Map.get(&1, "url"))
      |> Enum.take(10)

    %{
      "mode" => "deep_research",
      "requested_by_user" => Map.get(state, "requested_by_user", false),
      "reason" => Map.get(state, "reason", "deep_research"),
      "round_count" => length(rounds),
      "rounds" => rounds,
      "summary" => summary,
      "sources" => sources,
      "queries_executed" => Map.get(state, "queries_executed", []) ++ queries
    }
  end

  defp attach_research_context(context, nil), do: context

  defp attach_research_context(context, research_result) when is_map(research_result) do
    summary = fetch_result(research_result, "summary") || ""

    source_lines =
      research_result
      |> fetch_result("sources", [])
      |> normalize_source_list()
      |> Enum.map_join("\n", fn source ->
        title = Map.get(source, "title", "Untitled")
        url = Map.get(source, "url", "")
        "#{title}: #{url}"
      end)

    research_text =
      [
        Map.get(context, :context_text, ""),
        if(summary == "", do: nil, else: "Deep research summary:\n#{summary}"),
        if(source_lines == "", do: nil, else: "Deep research sources:\n#{source_lines}")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    Map.put(context, :context_text, research_text)
  end

  defp deep_research_enabled?(decision) when is_map(decision) do
    fetch_result(decision, "enabled") == true and
      normalize_queries(fetch_result(decision, "queries")) != []
  end

  defp fetch_result(map, key, default \\ nil) when is_map(map) do
    atom_key =
      case key do
        "enabled" -> :enabled
        "queries" -> :queries
        "requested_by_user" -> :requested_by_user
        "reason" -> :reason
        "max_rounds" -> :max_rounds
        "continue_research" -> :continue_research
        "follow_up_queries" -> :follow_up_queries
        "round_summary" -> :round_summary
        "sources" -> :sources
        _ -> nil
      end

    Map.get(map, key, atom_key && Map.get(map, atom_key, default))
  end

  defp normalize_queries(queries) when is_list(queries) do
    queries
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_queries(_queries), do: []

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) do
    case Integer.parse(to_string(value || "")) do
      {parsed, _} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_source_list(sources) when is_list(sources) do
    sources
    |> Enum.filter(&is_map/1)
  end

  defp normalize_source_list(_sources), do: []

  defp typing_activity(room_id, typing, run_id, workflow_id) do
    activity("set_typing", %{
      room_id: room_id || "",
      typing: typing,
      metadata: %{run_id: run_id, workflow_id: workflow_id}
    })
  end

  defp fetch_attr(map, key, default \\ nil) when is_map(map) do
    atom_key =
      case key do
        "room_id" -> :room_id
        "workflow_id" -> :workflow_id
        _ -> nil
      end

    Map.get(map, key, atom_key && Map.get(map, atom_key, default)) || default
  end
end
