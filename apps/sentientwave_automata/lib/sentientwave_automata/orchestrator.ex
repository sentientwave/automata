defmodule SentientwaveAutomata.Orchestrator do
  @moduledoc """
  Coordinates Matrix-triggered objectives through durable workflow adapters.
  """

  alias SentientwaveAutomata.Orchestration.Store
  alias SentientwaveAutomata.Orchestration.Workflow
  alias SentientwaveAutomata.Policy.Entitlements

  @spec start_workflow(map()) :: {:ok, Workflow.t()} | {:error, term()}
  def start_workflow(
        %{room_id: room_id, objective: objective, requested_by: requested_by} = attrs
      ) do
    with :ok <- validate_payload(attrs),
         true <- Entitlements.allowed?(:basic_orchestration, attrs),
         {:ok, temporal} <- temporal_adapter().start_workflow("conversation_workflow", attrs, []),
         :ok <-
           matrix_adapter().post_message(room_id, "Workflow started: #{objective}", %{
             requested_by: requested_by
           }) do
      workflow = %Workflow{
        workflow_id: temporal.workflow_id,
        run_id: temporal.run_id,
        room_id: room_id,
        objective: objective,
        status: temporal.status,
        requested_by: requested_by,
        inserted_at: DateTime.utc_now()
      }

      :ok = Store.put(workflow)
      {:ok, workflow}
    else
      false -> {:error, :feature_not_enabled}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec list_workflows() :: [Workflow.t()]
  def list_workflows, do: Store.list()

  defp validate_payload(%{room_id: room_id, objective: objective, requested_by: requested_by}) do
    if Enum.all?([room_id, objective, requested_by], &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, :invalid_payload}
    end
  end

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp temporal_adapter do
    Application.get_env(
      :sentientwave_automata,
      :temporal_adapter,
      SentientwaveAutomata.Adapters.Temporal.Local
    )
  end
end
