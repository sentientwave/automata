defmodule SentientwaveAutomata.Agents.CoordinatorAgent do
  @moduledoc """
  Primary coordinator for multi-agent workflows.

  In production this will orchestrate planner/reviewer/executor agents through
  Temporal child workflows. For now it returns a normalized plan payload.
  """

  @behaviour SentientwaveAutomata.Agents.Agent

  @impl true
  def role, do: :coordinator

  @impl true
  def execute(%{objective: objective} = input) when is_binary(objective) and objective != "" do
    {:ok,
     %{
       role: role(),
       objective: objective,
       plan: [
         %{step: "collect_context", status: :pending},
         %{step: "delegate_tasks", status: :pending},
         %{step: "review_and_publish", status: :pending}
       ],
       metadata: Map.drop(input, [:objective])
     }}
  end

  def execute(_), do: {:error, :invalid_objective}
end
