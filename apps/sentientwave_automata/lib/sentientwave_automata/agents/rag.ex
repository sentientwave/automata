defmodule SentientwaveAutomata.Agents.RAG do
  @moduledoc """
  Retrieval facade for agent-scoped memory contexts.
  """

  alias SentientwaveAutomata.Agents.MemoryStore

  @spec retrieve(binary(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def retrieve(agent_id, query, opts \\ []) do
    case Keyword.get(opts, :room_id) do
      room_id when is_binary(room_id) and room_id != "" ->
        # Two memory levels: the agent's main personal memory plus the room
        # thread for this specific room.
        with {:ok, personal} <- MemoryStore.search_personal(agent_id, query, opts),
             {:ok, room} <- MemoryStore.search_room(agent_id, room_id, query, opts) do
          personal_ctx = tag_level(personal, "personal")
          room_ctx = tag_level(room, "room")

          {:ok,
           %{
             query: query,
             room_id: room_id,
             contexts: room_ctx ++ personal_ctx,
             citations:
               Enum.map(room_ctx ++ personal_ctx, fn row ->
                 %{
                   memory_id: row.id,
                   source: row.source,
                   score: row.score,
                   memory_level: Map.get(row.metadata, "memory_level")
                 }
               end)
           }}
        end

      _ ->
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

  defp tag_level(rows, level) do
    Enum.map(rows, fn row ->
      row
      |> Map.update(:metadata, %{"memory_level" => level}, &Map.put(&1, "memory_level", level))
    end)
  end
end
