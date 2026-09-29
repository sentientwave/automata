defmodule SentientwaveAutomata.Agents.Workflow do
  @moduledoc """
  Temporal-owned agent run workflow.
  """

  alias SentientwaveAutomata.Agents.AgentLoop

  use TemporalSdk.Workflow

  alias SentientwaveAutomata.Agents.LawCompliance
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

    metadata = fetch_map(attrs, "metadata")
    autonomy? = Map.get(metadata, "room_autonomy", false) == true
    max_rounds = normalize_positive_integer(Map.get(metadata, "autonomy_max_rounds"), 1)

    participation =
      if autonomy? do
        activity("decide_participation", %{
          run_id: run_id,
          attrs: attrs,
          context: compacted_context
        })
      else
        %{"respond" => true, "reason" => "mentioned_or_direct_message"}
      end

    {final_response, final_status, final_error, delivery_mode, result_extra} =
      if truthy?(Map.get(participation, "respond", true)) do
        do_respond_rounds(run_id, attrs, compacted_context, autonomy?, "", 1, max_rounds)
      else
        {"", :succeeded, %{}, "silent", %{"participation" => participation, "rounds" => []}}
      end

    if final_response != "" do
      memory_context =
        attach_research_context(compacted_context, Map.get(result_extra, "research"))

      _ =
        activity("persist_memory", %{
          run_id: run_id,
          attrs: attrs,
          context: memory_context,
          response: final_response
        })

      _ =
        activity("consolidate_personal_memory", %{
          run_id: run_id,
          attrs: Map.put(attrs, "tool_context", Map.get(result_extra, "tool_results", [])),
          response: final_response
        })
    end

    _ =
      activity("mark_run_status", %{
        run_id: run_id,
        status: final_status,
        updates: %{
          result:
            Map.merge(
              %{
                response: final_response,
                context: %{
                  total_items: get_in(compacted_context, [:stats, :total_items]),
                  total_chars: get_in(compacted_context, [:stats, :total_chars]),
                  compaction: Map.get(compacted_context, :compaction, %{})
                },
                certification: Map.get(result_extra, "certification", %{}),
                delivery_mode: delivery_mode
              },
              result_extra
            ),
          error: final_error
        }
      })

    _ =
      typing_activity(
        fetch_attr(attrs, "room_id", ""),
        false,
        run_id,
        fetch_attr(attrs, "workflow_id")
      )

    %{response: final_response, context: compacted_context}
  rescue
    error ->
      reason = Exception.message(error)

      # Best-effort cleanup: if the original failure was Temporal/worker
      # unavailability, these activities would raise again and we would never
      # reach fail_workflow_execution (leaving the run "running" forever).
      try do
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
      rescue
        _ -> :ok
      end

      fail_workflow_execution(%{message: reason})
  end

  defp do_respond_rounds(
         run_id,
         attrs,
         context,
         autonomy?,
         previous_response,
         round_index,
         max_rounds
       ) do
    round_attrs =
      if round_index > 1 do
        original_body = attrs |> fetch_map("input") |> fetch_attr("body", "")

        body =
          "#{original_body}\n\n[Continuation round #{round_index}. Your previous response was:\n#{previous_response}\nContinue working if real follow-up remains.]"

        # Map.put instead of put_in: "input" may be absent, and put_in would
        # crash the whole workflow with a KeyError.
        Map.put(attrs, "input", Map.put(fetch_map(attrs, "input"), "body", body))
      else
        attrs
      end

    if round_index == 1 do
      # Human-paced reply: in group conversations agents pause briefly
      # before answering instead of all replying at once. The delay is
      # computed in an activity (safe randomness) but awaited with a
      # workflow timer so no activity worker slot is blocked while sleeping.
      pause = activity("human_pause", %{run_id: run_id, attrs: round_attrs})
      delay_ms = normalize_positive_integer(Map.get(pause, "paused_ms"), 0)

      if delay_ms > 0 do
        timer = start_timer(delay_ms)
        _ = wait_any([timer])
      end
    end

    # Accumulated tool results from the agentic loop; threaded into the
    # certifier so action claims can be grounded against real evidence.
    tool_context = []

    research_decision =
      if round_index > 1 do
        %{"enabled" => false, "reason" => "continuation_round"}
      else
        activity("assess_deep_research", %{
          run_id: run_id,
          attrs: round_attrs,
          context: context
        })
      end

    {response, research_result} =
      cond do
        round_index > 1 ->
          {activity("generate_response_without_tools", %{
             run_id: run_id,
             attrs: round_attrs,
             context: context
           }), nil}

        deep_research_enabled?(research_decision) ->
          research_result = run_deep_research(run_id, round_attrs, context, research_decision)

          response =
            activity("synthesize_deep_research_response", %{
              run_id: run_id,
              attrs: round_attrs,
              context: context,
              research: research_result
            })

          {response, research_result}

        true ->
          # Iterative agentic loop (ReAct-style, durable in the workflow):
          # plan -> execute -> feed results back into the planner -> repeat,
          # until the planner signals completion or a stop condition fires
          # (round budget, total tool-call budget, no-progress detection).
          {tool_context, loop_meta} = run_tool_loop(run_id, round_attrs, context)

          response =
            if tool_context == [] do
              activity("generate_response_without_tools", %{
                run_id: run_id,
                attrs: round_attrs,
                context: context
              })
            else
              activity("synthesize_response", %{
                run_id: run_id,
                attrs: round_attrs,
                context: context,
                tool_context: tool_context,
                agent_loop: loop_meta
              })
            end

          # surface loop evidence for certification + memory consolidation
          {response,
           %{
             "agent_loop" => loop_meta,
             "tool_results" => Enum.take(tool_context, -20)
           }}
      end

    certification =
      activity("certify_response", %{
        run_id: run_id,
        attrs: round_attrs,
        context: context,
        response: response,
        tool_context: tool_context
      })

    {round_response, round_status, round_error, round_delivery} =
      case LawCompliance.certified?(certification) do
        true ->
          {response, :succeeded, %{}, "certified_response"}

        false ->
          {
            LawCompliance.blocked_response(certification),
            :failed,
            %{
              reason: "Agent response was blocked by the law certification guard.",
              kind: "law_certification_blocked",
              certification: certification
            },
            "lawful_fallback"
          }
      end

    if round_response |> to_string() |> String.trim() != "" do
      _ =
        activity("post_response", %{run_id: run_id, attrs: round_attrs, response: round_response})
    end

    continuation =
      if autonomy? and round_status == :succeeded and round_index < max_rounds do
        activity("assess_continuation", %{
          run_id: run_id,
          attrs: attrs,
          context: context,
          response: round_response
        })
      else
        %{"continue" => false, "reason" => "round_limit_or_blocked"}
      end

    round_record = %{
      "round_index" => round_index,
      "response" => round_response,
      "delivery_mode" => round_delivery,
      "certification" => certification,
      "research" => research_result || %{"mode" => "standard"},
      "continuation" => continuation
    }

    if truthy?(Map.get(continuation, "continue", false)) do
      {next_response, next_status, next_error, next_delivery, next_extra} =
        do_respond_rounds(
          run_id,
          attrs,
          context,
          autonomy?,
          round_response,
          round_index + 1,
          max_rounds
        )

      {next_response, next_status, next_error, next_delivery,
       %{
         "certification" => Map.get(next_extra, "certification", certification),
         "rounds" => [round_record | Map.get(next_extra, "rounds", [])],
         "research" =>
           Map.get(next_extra, "research", research_result || %{"mode" => "standard"}),
         "participation" => %{"respond" => true, "reason" => "participated"}
       }}
    else
      {round_response, round_status, round_error, round_delivery,
       %{
         "certification" => certification,
         "rounds" => [round_record],
         "research" => research_result || %{"mode" => "standard"},
         "participation" => %{"respond" => true, "reason" => "participated"}
       }}
    end
  end

  defp truthy?(value), do: value in [true, "true", "TRUE", "1", 1]

  defp fetch_map(map, key) when is_map(map), do: Map.get(map, key, %{})
  defp fetch_map(_map, _key), do: %{}

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

  # Iterative agentic tool loop: bounded rounds of plan -> execute with
  # accumulated results fed back into the planner. Durable: every LLM call and
  # tool batch is an activity, so worker crashes resume mid-loop.
  defp run_tool_loop(run_id, attrs, context) do
    do_tool_round(run_id, attrs, context, 1, [], %{"last" => nil, "streak" => 0})
  end

  defp do_tool_round(run_id, attrs, context, round, acc, tracker) do
    if round > AgentLoop.max_tool_rounds() or length(acc) >= AgentLoop.max_tool_calls() do
      do_tool_round_done(round, acc)
    else
      do_tool_round_active(run_id, attrs, context, round, acc, tracker)
    end
  end

  defp do_tool_round_done(round, acc),
    do: {acc, %{action: :done, reason: "round_budget", rounds_used: max(round - 1, 0)}}

  defp do_tool_round_active(run_id, attrs, context, round, acc, tracker) do
    # Refresh context between rounds so events posted since the run started
    # (the live event stream) are visible to the planner.
    context =
      if round == 1 do
        context
      else
        case activity("build_context", %{"run_id" => run_id, "attrs" => attrs}) do
          [refreshed] when is_map(refreshed) -> refreshed
          _ -> context
        end
      end

    plan =
      activity("plan_tool_calls", %{
        run_id: run_id,
        attrs: attrs,
        context: context,
        tool_context: acc,
        tool_round: round
      })
      |> List.wrap()

    fingerprint = AgentLoop.fingerprint(plan)

    {streak, tracker} =
      if tracker["last"] == fingerprint do
        {tracker["streak"] + 1, tracker}
      else
        {1, %{"last" => fingerprint, "streak" => 1}}
      end

    decision =
      AgentLoop.next_action(%{
        plan: plan,
        fingerprint: fingerprint,
        streak: streak,
        tool_calls_so_far: length(acc),
        max_tool_calls: AgentLoop.max_tool_calls(),
        round: round,
        max_rounds: AgentLoop.max_tool_rounds()
      })

    case decision.action do
      :done ->
        {acc, Map.put(decision, :rounds_used, max(round - 1, 0))}

      :execute_plan ->
        results = activity("execute_tool_calls", %{run_id: run_id, tool_calls: plan})
        acc = List.wrap(acc) ++ List.wrap(results)

        if length(acc) >= AgentLoop.max_tool_calls() do
          {acc, %{action: :done, reason: "tool_budget", rounds_used: round}}
        else
          do_tool_round(run_id, attrs, context, round + 1, acc, tracker)
        end
    end
  end
end
