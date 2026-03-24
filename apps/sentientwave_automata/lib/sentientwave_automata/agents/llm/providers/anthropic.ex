defmodule SentientwaveAutomata.Agents.LLM.Providers.Anthropic do
  @moduledoc false

  @behaviour SentientwaveAutomata.Agents.LLMProvider

  alias SentientwaveAutomata.Agents.LLM.HTTP

  @default_model "claude-sonnet-4-6"
  @default_base_url "https://api.anthropic.com"
  @default_version "2023-06-01"
  @default_max_tokens 1024

  @impl true
  def complete(messages, opts \\ []) when is_list(messages) do
    model = Keyword.get(opts, :model, System.get_env("AUTOMATA_LLM_MODEL", @default_model))

    base_url =
      Keyword.get(opts, :base_url, System.get_env("AUTOMATA_LLM_API_BASE", @default_base_url))

    api_key =
      Keyword.get(
        opts,
        :api_key,
        System.get_env("AUTOMATA_LLM_API_KEY", System.get_env("ANTHROPIC_API_KEY", ""))
      )

    anthropic_version =
      Keyword.get(
        opts,
        :anthropic_version,
        System.get_env("AUTOMATA_LLM_ANTHROPIC_VERSION", @default_version)
      )

    if String.trim(api_key) == "" do
      {:error, :missing_api_key}
    else
      {system_prompt, anthropic_messages} = normalize_messages(messages)

      payload =
        %{
          "model" => model,
          "max_tokens" => max_tokens(opts),
          "messages" => anthropic_messages
        }
        |> maybe_put_system(system_prompt)

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", anthropic_version}
      ]

      url = String.trim_trailing(base_url, "/") <> "/v1/messages"

      with {:ok, status, body} <- HTTP.post_json(url, headers, payload, opts),
           {:ok, text} <- handle_response(status, body) do
        {:ok, text}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp handle_response(status, body) when status in 200..299, do: extract_text(body)
  defp handle_response(status, body), do: {:error, {:http_error, status, body}}

  defp normalize_messages(messages) do
    {system_fragments, normalized_messages} =
      Enum.reduce(messages, {[], []}, fn
        %{"role" => "system", "content" => content}, {system_acc, message_acc}
        when is_binary(content) ->
          {[String.trim(content) | system_acc], message_acc}

        %{"role" => role, "content" => content}, {system_acc, message_acc}
        when role in ["user", "assistant"] and is_binary(content) ->
          {system_acc, append_message(message_acc, %{"role" => role, "content" => content})}

        _, acc ->
          acc
      end)

    system_prompt =
      system_fragments
      |> Enum.reverse()
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    {blank_to_nil(system_prompt), Enum.reverse(normalized_messages)}
  end

  defp append_message(
         [%{"role" => role, "content" => existing} | rest],
         %{"role" => role, "content" => content}
       ) do
    merged_content =
      [String.trim(existing), String.trim(content)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    [%{"role" => role, "content" => merged_content} | rest]
  end

  defp append_message(messages, message), do: [message | messages]

  defp maybe_put_system(payload, nil), do: payload
  defp maybe_put_system(payload, system_prompt), do: Map.put(payload, "system", system_prompt)

  defp extract_text(%{"content" => content}) when is_list(content) do
    text =
      content
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => value} when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: [], else: [trimmed]

        _ ->
          []
      end)
      |> Enum.join("\n\n")

    case blank_to_nil(text) do
      nil -> {:error, {:invalid_response, %{"content" => content}}}
      normalized_text -> {:ok, normalized_text}
    end
  end

  defp extract_text(body), do: {:error, {:invalid_response, body}}

  defp max_tokens(opts) do
    value =
      Keyword.get(
        opts,
        :max_tokens,
        System.get_env(
          "AUTOMATA_LLM_ANTHROPIC_MAX_TOKENS",
          Integer.to_string(@default_max_tokens)
        )
      )

    case value do
      number when is_integer(number) and number > 0 ->
        number

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {parsed, _} when parsed > 0 -> parsed
          _ -> @default_max_tokens
        end

      _ ->
        @default_max_tokens
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
