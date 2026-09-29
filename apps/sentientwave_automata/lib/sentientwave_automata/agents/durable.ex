defmodule SentientwaveAutomata.Agents.Durable do
  @moduledoc """
  Durable execution facade for agent runs.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Run
  alias SentientwaveAutomata.Agents.Runtime
  alias SentientwaveAutomata.Temporal

  @spec start_run(map()) :: {:ok, Run.t()} | {:error, term()}
  def start_run(%{agent_id: agent_id} = attrs) do
    constitution_snapshot = Runtime.current_constitution_snapshot()
    constitution_metadata = Runtime.constitution_snapshot_metadata(constitution_snapshot)
    workflow_id = Temporal.generated_workflow_id("agent_run")
    run_metadata = Map.merge(Map.get(attrs, :metadata, %{}), constitution_metadata)
    attrs = Map.merge(attrs, constitution_metadata)

    with {:ok, run} <-
           Agents.create_run(%{
             agent_id: agent_id,
             mention_id: Map.get(attrs, :mention_id),
             workflow_id: workflow_id,
             status: :queued,
             metadata: run_metadata
           }) do
      start_temporal_run(run, attrs, workflow_id, run_metadata)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  # B13: without compensation the run row would sit in :queued forever (no
  # workflow behind it) whenever the Temporal start fails.
  defp start_temporal_run(run, attrs, workflow_id, run_metadata) do
    case temporal_adapter().start_agent_run(%{
           workflow_id: workflow_id,
           run_id: run.id,
           attrs: attrs
         }) do
      {:ok, temporal} ->
        Agents.update_run(run, %{
          temporal_run_id: temporal.run_id,
          status: :running,
          metadata: Map.put(run_metadata, "temporal_source", "temporal_sdk")
        })

      {:error, reason} = error ->
        _ =
          Agents.update_run(run, %{
            status: :failed,
            error: %{"reason" => inspect(reason), "stage" => "temporal_start"}
          })

        error
    end
  end

  @spec signal_run(String.t(), map()) :: :ok | {:error, term()}
  def signal_run(workflow_id, payload) do
    temporal_adapter().signal_agent_run(workflow_id, payload)
  end

  @spec query_run(String.t()) :: {:ok, map()} | {:error, term()}
  def query_run(workflow_id), do: temporal_adapter().query_agent_run(workflow_id)

  defp temporal_adapter do
    Application.get_env(
      :sentientwave_automata,
      :temporal_adapter,
      SentientwaveAutomata.Adapters.Temporal.Runtime
    )
  end
end
