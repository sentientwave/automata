defmodule SentientwaveAutomata.Agents.MemoryStore do
  @moduledoc """
  Per-agent memory ingestion and similarity retrieval.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Memory
  alias SentientwaveAutomata.Repo

  @spec ingest(binary(), String.t(), keyword()) :: {:ok, Memory.t()} | {:error, term()}
  def ingest(agent_id, content, opts \\ []) when is_binary(content) do
    provider = Keyword.get(opts, :provider, embedding_provider())
    dim = Keyword.get(opts, :dim, embedding_dim())

    with {:ok, embedding} <- provider.embed(content, dim: dim) do
      Agents.create_memory(%{
        agent_id: agent_id,
        source: Keyword.get(opts, :source),
        content: content,
        embedding: embedding,
        metadata: Keyword.get(opts, :metadata, %{})
      })
    end
  end

  @spec search(binary(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(agent_id, query_text, opts \\ []) when is_binary(query_text) do
    provider = Keyword.get(opts, :provider, embedding_provider())
    dim = Keyword.get(opts, :dim, embedding_dim())

    with {:ok, query_embedding} <- provider.embed(query_text, dim: dim) do
      top_k = Keyword.get(opts, :top_k, 5)

      rows =
        Repo.all(
          from m in Memory,
            where: m.agent_id == ^agent_id,
            select: %{
              id: m.id,
              content: m.content,
              source: m.source,
              metadata: m.metadata,
              inserted_at: m.inserted_at,
              embedding: m.embedding
            }
        )
        |> Enum.map(fn row ->
          Map.put(row, :score, cosine_similarity(row.embedding || [], query_embedding))
        end)
        |> Enum.sort_by(& &1.score, :desc)
        |> Enum.take(top_k)
        |> Enum.map(&Map.delete(&1, :embedding))

      {:ok, rows}
    end
  end

  defp embedding_provider do
    Application.get_env(
      :sentientwave_automata,
      :embedding_provider,
      SentientwaveAutomata.Agents.Embedding.Local
    )
  end

  defp embedding_dim do
    Application.get_env(:sentientwave_automata, :embedding_dim, 64)
  end

  defp cosine_similarity([], _), do: 0.0
  defp cosine_similarity(_, []), do: 0.0

  defp cosine_similarity(a, b) do
    len = min(length(a), length(b))
    a = Enum.take(a, len)
    b = Enum.take(b, len)

    dot = Enum.zip(a, b) |> Enum.reduce(0.0, fn {x, y}, acc -> acc + x * y end)
    na = :math.sqrt(Enum.reduce(a, 0.0, fn x, acc -> acc + x * x end))
    nb = :math.sqrt(Enum.reduce(b, 0.0, fn x, acc -> acc + x * x end))

    if na == 0.0 or nb == 0.0, do: 0.0, else: dot / (na * nb)
  end
end
