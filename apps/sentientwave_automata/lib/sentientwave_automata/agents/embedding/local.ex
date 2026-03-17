defmodule SentientwaveAutomata.Agents.Embedding.Local do
  @moduledoc """
  Deterministic local embedding provider for demo/local use.
  """

  @behaviour SentientwaveAutomata.Agents.EmbeddingProvider

  @impl true
  def embed(text, opts \\ []) when is_binary(text) do
    dim = Keyword.get(opts, :dim, default_dim())

    if dim <= 0 do
      {:error, :invalid_dim}
    else
      tokens =
        text
        |> String.downcase()
        |> String.split(~r/[^a-z0-9]+/, trim: true)

      base = List.duplicate(0.0, dim)

      vector =
        Enum.reduce(tokens, base, fn token, acc ->
          idx = :erlang.phash2(token, dim)
          List.update_at(acc, idx, &(&1 + 1.0))
        end)

      {:ok, normalize(vector)}
    end
  end

  defp default_dim do
    System.get_env("AUTOMATA_EMBEDDING_DIM", "64")
    |> String.to_integer()
  rescue
    _ -> 64
  end

  defp normalize(values) do
    magnitude = :math.sqrt(Enum.reduce(values, 0.0, fn v, acc -> acc + v * v end))

    if magnitude <= 0.0 do
      values
    else
      Enum.map(values, &(&1 / magnitude))
    end
  end
end
