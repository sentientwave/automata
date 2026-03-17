defmodule SentientwaveAutomata.Agents.Tools.HTTP do
  @moduledoc false

  @spec get_json(String.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, integer(), map()} | {:error, term()}
  def get_json(url, headers, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_timeout())
    connect_timeout = Keyword.get(opts, :connect_timeout, default_connect_timeout())

    req_headers =
      headers
      |> Enum.map(fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req = {to_charlist(url), req_headers}
    http_opts = [timeout: timeout, connect_timeout: connect_timeout]

    case :httpc.request(:get, req, http_opts, body_format: :binary) do
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
    System.get_env("AUTOMATA_TOOL_HTTP_TIMEOUT_MS", "12000")
    |> String.to_integer()
  rescue
    _ -> 12_000
  end

  defp default_connect_timeout do
    System.get_env("AUTOMATA_TOOL_HTTP_CONNECT_TIMEOUT_MS", "3000")
    |> String.to_integer()
  rescue
    _ -> 3_000
  end
end
