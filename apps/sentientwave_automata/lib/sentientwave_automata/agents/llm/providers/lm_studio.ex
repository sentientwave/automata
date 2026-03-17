defmodule SentientwaveAutomata.Agents.LLM.Providers.LMStudio do
  @moduledoc false

  @behaviour SentientwaveAutomata.Agents.LLMProvider

  alias SentientwaveAutomata.Agents.LLM.HTTP

  @impl true
  def complete(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, System.get_env("AUTOMATA_LLM_MODEL", "local-model"))

    base_url =
      Keyword.get(
        opts,
        :base_url,
        System.get_env("AUTOMATA_LLM_API_BASE", "http://127.0.0.1:1234/v1")
      )

    api_key = Keyword.get(opts, :api_key, System.get_env("AUTOMATA_LLM_API_KEY", "lm-studio"))
    url = String.trim_trailing(base_url, "/") <> "/chat/completions"

    payload = %{
      "model" => model,
      "messages" => messages,
      "temperature" => 0.2
    }

    headers =
      if String.trim(api_key) == "" do
        []
      else
        [{"authorization", "Bearer " <> api_key}]
      end

    with {:ok, status, body} <- HTTP.post_json(url, headers, payload, opts),
         true <- status in 200..299,
         {:ok, text} <- extract_text(body) do
      {:ok, text}
    else
      false -> {:error, :http_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, String.trim(content)}
  end

  defp extract_text(body), do: {:error, {:invalid_response, body}}
end
