defmodule SentientwaveAutomata.Agents.LLM.HTTP do
  @moduledoc false

  @spec post_json(String.t(), [{String.t(), String.t()}], map(), keyword()) ::
          {:ok, integer(), map()} | {:error, term()}
  def post_json(url, headers, payload, opts \\ []) do
    body = Jason.encode!(payload)

    timeout =
      Keyword.get(opts, :timeout, timeout_from_seconds(Keyword.get(opts, :timeout_seconds, nil)))

    connect_timeout = Keyword.get(opts, :connect_timeout, default_connect_timeout())

    req_headers =
      [{"content-type", "application/json"} | headers]
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req = {to_charlist(url), req_headers, ~c"application/json", body}
    http_opts = [timeout: timeout, connect_timeout: connect_timeout]

    case :httpc.request(:post, req, http_opts, body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        decode_json(status, resp_body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_json(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, status, json}
      {:error, reason} -> {:error, {:invalid_json_response, reason, body}}
    end
  end

  defp default_timeout do
    System.get_env("AUTOMATA_LLM_TIMEOUT_MS", "600000")
    |> String.to_integer()
  rescue
    _ -> 600_000
  end

  defp timeout_from_seconds(seconds) when is_integer(seconds) and seconds > 0 do
    seconds * 1000
  end

  defp timeout_from_seconds(seconds) when is_binary(seconds) do
    case Integer.parse(String.trim(seconds)) do
      {parsed, _} when parsed > 0 -> parsed * 1000
      _ -> default_timeout()
    end
  end

  defp timeout_from_seconds(_), do: default_timeout()

  defp default_connect_timeout do
    System.get_env("AUTOMATA_LLM_CONNECT_TIMEOUT_MS", "3000")
    |> String.to_integer()
  rescue
    _ -> 3_000
  end
end
