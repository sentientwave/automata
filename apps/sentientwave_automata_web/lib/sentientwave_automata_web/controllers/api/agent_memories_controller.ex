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
    top_k = params |> Map.get("top_k", "5") |> parse_top_k()

    case MemoryStore.search(agent_id, query, top_k: top_k) do
      {:ok, rows} -> json(conn, %{data: rows})
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  # Invalid input used to raise ArgumentError (unhandled 500); treat it as the
  # default and clamp huge values so a client cannot force an unbounded scan.
  defp parse_top_k(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 -> min(n, 50)
      _ -> 5
    end
  end
end
