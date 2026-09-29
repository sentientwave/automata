defmodule SentientwaveAutomata.Agents.LLM.Providers.DeepSeek do
  @moduledoc false

  @behaviour SentientwaveAutomata.Agents.LLMProvider

  alias SentientwaveAutomata.Agents.LLM.HTTP

  @impl true
  def complete(messages, opts \\ []) when is_list(messages) do
    model =
      Keyword.get(opts, :model, System.get_env("AUTOMATA_LLM_MODEL", "deepseek-v4-pro"))

    base_url =
      Keyword.get(
        opts,
        :base_url,
        System.get_env("AUTOMATA_LLM_API_BASE", "https://api.deepseek.com/v1")
      )

    api_key =
      Keyword.get(
        opts,
        :api_key,
        System.get_env("AUTOMATA_LLM_API_KEY", System.get_env("DEEPSEEK_API_KEY", ""))
      )

    if String.trim(api_key) == "" do
      {:error, :missing_api_key}
    else
      url = String.trim_trailing(base_url, "/") <> "/chat/completions"

      payload = %{
        "model" => model,
        "messages" => messages,
        "temperature" => 0.2
      }

      payload =
        if Keyword.get(opts, :response_format) == :json_object do
          Map.put(payload, "response_format", %{"type" => "json_object"})
        else
          payload
        end

      headers = [{"authorization", "Bearer " <> api_key}]

      with {:ok, status, body} <- HTTP.post_json(url, headers, payload, opts),
           true <- status in 200..299,
           {:ok, text} <- extract_text(body) do
        {:ok, text}
      else
        false -> {:error, :http_error}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp extract_text(%{"choices" => [%{"message" => %{"content" => content}} | _]})
       when is_binary(content) do
    {:ok, String.trim(content)}
  end

  defp extract_text(body), do: {:error, {:invalid_response, body}}
end
