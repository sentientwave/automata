defmodule SentientwaveAutomataWeb.API.AgentMemoriesController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Agents.MemoryStore

  def create(conn, %{"agent_id" => agent_id} = params) do
    case MemoryStore.ingest(agent_id, Map.get(params, "content", ""),
           source: Map.get(params, "source"),
           metadata: Map.get(params, "metadata", %{})
         ) do
      {:ok, memory} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{id: memory.id, agent_id: memory.agent_id, inserted_at: memory.inserted_at}
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  def search(conn, %{"agent_id" => agent_id, "query" => query} = params) do
    top_k = params |> Map.get("top_k", "5") |> to_string() |> String.to_integer()

    case MemoryStore.search(agent_id, query, top_k: top_k) do
      {:ok, rows} -> json(conn, %{data: rows})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end
end
