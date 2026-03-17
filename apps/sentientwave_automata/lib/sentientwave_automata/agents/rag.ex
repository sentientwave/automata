defmodule SentientwaveAutomata.Agents.RAG do
  @moduledoc """
  Retrieval facade for agent-scoped memory contexts.
  """

  alias SentientwaveAutomata.Agents.MemoryStore

  @spec retrieve(binary(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve(agent_id, query, opts \\ []) do
    with {:ok, rows} <- MemoryStore.search(agent_id, query, opts) do
      {:ok,
       %{
         query: query,
         contexts: rows,
         citations:
           Enum.map(rows, fn row ->
             %{memory_id: row.id, source: row.source, score: row.score}
           end)
       }}
    end
  end
end
