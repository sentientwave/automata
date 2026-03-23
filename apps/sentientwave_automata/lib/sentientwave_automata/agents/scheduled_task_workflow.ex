defmodule SentientwaveAutomata.Agents.ScheduledTaskWorkflow do
  @moduledoc """
  Temporal-owned scheduler for one persisted scheduled task definition.
  """

  use TemporalSdk.Workflow

  alias SentientwaveAutomata.Temporal

  @activity SentientwaveAutomata.Agents.ScheduledTaskActivities
  @refresh_signal "refresh"
  @stop_signal "stop"

  @impl true
  def execute(_context, [%{"task_id" => task_id}]) do
    loop(task_id)
  end

  defp loop(task_id) do
    task_state = activity("load_task_state", %{task_id: task_id})

    cond do
      task_state["state"] == "missing" ->
        %{status: "stopped", reason: "missing"}

      task_state["enabled"] != true ->
        %{status: "stopped", reason: "disabled"}

      true ->
        wait_ms = Map.get(task_state, "wait_ms", 0)
        timer = start_timer(wait_ms)

        case wait_one([
               timer,
               {:signal_request, @refresh_signal},
               {:signal_request, @stop_signal}
             ]) do
          [%{state: :fired}, :noevent, :noevent] ->
            _ = activity("execute_task", %{task_id: task_id})
            loop(task_id)

          [:noevent, refresh_signal, :noevent] ->
            _ = admit_signal(@refresh_signal, wait: true)
            _ = refresh_signal
            loop(task_id)

          [:noevent, :noevent, stop_signal] ->
            _ = admit_signal(@stop_signal, wait: true)
            _ = stop_signal
            %{status: "stopped", reason: "signaled"}
        end
    end
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

  defp unwrap_activity_result({:ok, result}), do: result
  defp unwrap_activity_result([result]), do: result
  defp unwrap_activity_result(result), do: result
end
