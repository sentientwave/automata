defmodule SentientwaveAutomata.Adapters.Temporal.Local do
  @moduledoc """
  Local in-memory Temporal adapter substitute.

  This lets us exercise orchestration flows before wiring a bridge service.
  """

  @behaviour SentientwaveAutomata.Adapters.Temporal.Behaviour

  @impl true
  def start_workflow(workflow_name, input, _opts) do
    workflow_id = "wf_" <> Ecto.UUID.generate()
    run_id = "run_" <> Ecto.UUID.generate()

    _ = {workflow_name, input}

    {:ok, %{workflow_id: workflow_id, run_id: run_id, status: :running}}
  end

  @impl true
  def signal_workflow(_workflow_id, _signal, _payload), do: :ok

  @impl true
  def start_agent_run(input), do: start_workflow("agent_workflow", input, [])

  @impl true
  def signal_agent_run(workflow_id, payload),
    do: signal_workflow(workflow_id, "agent_signal", payload)

  @impl true
  def query_agent_run(workflow_id) do
    {:ok, %{workflow_id: workflow_id, status: :running, source: :local_adapter}}
  end
end
