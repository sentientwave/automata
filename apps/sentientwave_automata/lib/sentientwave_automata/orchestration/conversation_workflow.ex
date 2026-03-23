defmodule SentientwaveAutomata.Orchestration.ConversationWorkflow do
  @moduledoc """
  Temporal-owned generic conversation workflow.
  """

  use TemporalSdk.Workflow

  alias SentientwaveAutomata.Temporal

  @activity SentientwaveAutomata.Orchestration.Activities

  @impl true
  def execute(_context, [%{"workflow_id" => workflow_id, "attrs" => attrs}]) do
    _ = activity("mark_status", %{workflow_id: workflow_id, status: "running"})
    result = activity("post_started_message", %{workflow_id: workflow_id, attrs: attrs})
    _ = activity("mark_status", %{workflow_id: workflow_id, status: "succeeded", result: result})
    %{workflow_id: workflow_id, status: "succeeded"}
  rescue
    error ->
      reason = Exception.message(error)

      _ =
        activity("mark_status", %{
          workflow_id: workflow_id,
          status: "failed",
          error: %{"reason" => reason}
        })

      fail_workflow_execution(%{message: reason})
  end

  defp activity(step, payload) do
    [%{result: result}] =
      wait_all([
        start_activity(
          @activity,
          [Temporal.activity_payload(step, payload)],
          task_queue: Temporal.activity_task_queue(),
          start_to_close_timeout: {5, :minute}
        )
      ])

    unwrap_activity_result(result)
  end

  defp unwrap_activity_result([value]), do: value
  defp unwrap_activity_result({:ok, value}), do: value
  defp unwrap_activity_result(value), do: value
end
