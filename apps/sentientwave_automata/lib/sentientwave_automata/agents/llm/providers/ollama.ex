defmodule SentientwaveAutomata.Agents.LLM.Providers.Ollama do
  @moduledoc false

  @behaviour SentientwaveAutomata.Agents.LLMProvider

  alias SentientwaveAutomata.Agents.LLM.HTTP

  @impl true
  def complete(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, System.get_env("AUTOMATA_LLM_MODEL", "llama3.1"))

    base_url =
      Keyword.get(
        opts,
        :base_url,
        System.get_env("AUTOMATA_LLM_API_BASE", "http://127.0.0.1:11434")
      )

    url = String.trim_trailing(base_url, "/") <> "/api/chat"

    payload = %{
      "model" => model,
      "messages" => messages,
      "stream" => false,
      "options" => %{"temperature" => 0.2}
    }

    with {:ok, status, body} <- HTTP.post_json(url, [], payload, opts),
         true <- status in 200..299,
         {:ok, text} <- extract_text(body) do
      {:ok, text}
    else
      false -> {:error, :http_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_text(%{"message" => %{"content" => content}}) when is_binary(content) do
    {:ok, String.trim(content)}
  end

  defp extract_text(body), do: {:error, {:invalid_response, body}}
end
