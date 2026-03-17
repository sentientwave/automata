defmodule SentientwaveAutomata.Orchestration.Store do
  @moduledoc """
  In-memory store for workflow summaries.

  This is intentionally replaceable with Ecto-backed persistence.
  """

  use Agent

  alias SentientwaveAutomata.Orchestration.Workflow

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @spec put(Workflow.t()) :: :ok
  def put(%Workflow{} = workflow) do
    Agent.update(__MODULE__, &Map.put(&1, workflow.workflow_id, workflow))
  end

  @spec list() :: [Workflow.t()]
  def list do
    __MODULE__
    |> Agent.get(&Map.values(&1))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end
end
