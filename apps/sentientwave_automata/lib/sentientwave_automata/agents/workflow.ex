defmodule SentientwaveAutomata.Agents.Workflow do
  @moduledoc """
  Agent durable workflow orchestrator.

  Workflow coordinates pure orchestration and delegates side effects to activities.
  """

  alias SentientwaveAutomata.Agents.Activities
  alias SentientwaveAutomata.Agents.Run

  @spec execute(Run.t(), map()) ::
          {:ok, %{response: String.t(), context: map()}} | {:error, term()}
  def execute(%Run{} = run, attrs) do
    with {:ok, base_context} <- Activities.build_context(run, attrs),
         {:ok, compacted_context} <- Activities.compact_context(run, base_context),
         {:ok, response} <- Activities.generate_response(run, attrs, compacted_context),
         :ok <- Activities.post_response(run, attrs, response),
         :ok <- Activities.persist_memory(run, attrs, compacted_context, response) do
      {:ok, %{response: response, context: compacted_context}}
    end
  end
end
