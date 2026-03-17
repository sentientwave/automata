defmodule SentientwaveAutomata.Matrix.Onboarding.Invites do
  @moduledoc """
  Helpers for parsing onboarding invite lists from deploy scripts.
  """

  @matrix_user_id_regex ~r/^@[A-Za-z0-9._=\/-]+:[A-Za-z0-9.-]+$/
  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @spec parse(nil | String.t() | [term()]) :: {:ok, [String.t()]} | {:error, atom()}
  def parse(nil), do: {:ok, []}

  def parse(raw) when is_binary(raw) do
    raw
    |> String.split([",", "\n"], trim: true)
    |> parse()
  end

  def parse(raw) when is_list(raw) do
    normalized =
      raw
      |> Enum.map(&normalize/1)

    if Enum.any?(normalized, &match?(:error, &1)) do
      {:error, :invalid_invites}
    else
      invites =
        normalized
        |> Enum.map(fn {:ok, value} -> value end)
        |> Enum.uniq()

      {:ok, invites}
    end
  end

  def parse(_), do: {:error, :invalid_invites}

  @spec matrix_user_id?(String.t()) :: boolean()
  def matrix_user_id?(value) when is_binary(value), do: value =~ @matrix_user_id_regex
  def matrix_user_id?(_), do: false

  defp normalize(value) when is_binary(value) do
    candidate = String.trim(value)

    cond do
      candidate == "" -> :error
      matrix_user_id?(candidate) -> {:ok, candidate}
      candidate =~ @email_regex -> {:ok, String.downcase(candidate)}
      true -> :error
    end
  end

  defp normalize(_), do: :error
end
