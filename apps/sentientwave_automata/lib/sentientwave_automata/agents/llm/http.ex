defmodule SentientwaveAutomata.Agents.LLM.HTTP do
  @moduledoc false

  @spec post_json(String.t(), [{String.t(), String.t()}], map(), keyword()) ::
          {:ok, integer(), map()} | {:error, term()}
  def post_json(url, headers, payload, opts \\ []) do
    timeout =
      Keyword.get(opts, :timeout, timeout_from_seconds(Keyword.get(opts, :timeout_seconds, nil)))

    connect_timeout = Keyword.get(opts, :connect_timeout, default_connect_timeout())
    request_headers = [{"content-type", "application/json"} | headers]

    case Req.post(
           url: url,
           headers: request_headers,
           json: payload,
           receive_timeout: timeout,
           connect_options: [timeout: connect_timeout],
           retry: false
         ) do
      {:ok, %Req.Response{status: status, body: body}} ->
        decode_body(status, body)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_body(status, body) when is_map(body) do
    {:ok, status, body}
  end

  defp decode_body(status, body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, json} -> {:ok, status, json}
      {:error, reason} -> {:error, {:invalid_json_response, reason, body}}
    end
  end

  defp decode_body(_status, body), do: {:error, {:unexpected_response_body, body}}

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
