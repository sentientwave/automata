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
          tool_context = activity("execute_tool_calls", %{run_id: run_id, tool_calls: tool_calls})

          activity("synthesize_response", %{
            run_id: run_id,
            attrs: attrs,
            context: compacted_context,
            tool_context: tool_context
          })
      end

    _ = activity("post_response", %{run_id: run_id, attrs: attrs, response: response})

    _ =
      activity("persist_memory", %{
        run_id: run_id,
        attrs: attrs,
        context: compacted_context,
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
            }
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
  defp unwrap_activity_result({:ok, result}), do: result
  defp unwrap_activity_result(result), do: result

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
