defmodule SentientwaveAutomata.Agents.LLM.Providers.Gemini do
  @moduledoc false

  @behaviour SentientwaveAutomata.Agents.LLMProvider

  alias SentientwaveAutomata.Agents.LLM.HTTP

  @default_model "gemini-3.1-pro-preview"
  @default_base_url "https://generativelanguage.googleapis.com/v1beta"
  @default_max_output_tokens 1024

  @impl true
  def complete(messages, opts \\ []) when is_list(messages) do
    model =
      opts
      |> Keyword.get(:model, System.get_env("AUTOMATA_LLM_MODEL", @default_model))
      |> normalize_model()

    base_url =
      Keyword.get(opts, :base_url)
      |> blank_to_nil()
      |> case do
        nil -> System.get_env("AUTOMATA_LLM_API_BASE", @default_base_url)
        configured_base_url -> configured_base_url
      end

    api_key =
      Keyword.get(opts, :api_key)
      |> blank_to_nil()
      |> case do
        nil ->
          System.get_env(
            "AUTOMATA_LLM_API_KEY",
            System.get_env("GEMINI_API_KEY", System.get_env("GOOGLE_API_KEY", ""))
          )

        configured_api_key ->
          configured_api_key
      end

    if String.trim(api_key) == "" do
      {:error, :missing_api_key}
    else
      {system_instruction, contents} = normalize_messages(messages)

      payload =
        %{
          "contents" => contents,
          "generationConfig" => %{
            "temperature" => 0.2
          }
        }
        |> maybe_put_system_instruction(system_instruction)
        |> maybe_put_max_output_tokens(max_output_tokens(opts))

      url =
        String.trim_trailing(base_url, "/") <>
          "/models/" <> URI.encode(model) <> ":generateContent"

      headers = [{"x-goog-api-key", api_key}]

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
    {system_fragments, contents} =
      Enum.reduce(messages, {[], []}, fn
        %{"role" => "system", "content" => content}, {system_acc, content_acc}
        when is_binary(content) ->
          {[String.trim(content) | system_acc], content_acc}

        %{"role" => role, "content" => content}, {system_acc, content_acc}
        when role in ["user", "assistant"] and is_binary(content) ->
          {system_acc, append_content(content_acc, gemini_role(role), String.trim(content))}

        _, acc ->
          acc
      end)

    system_instruction =
      system_fragments
      |> Enum.reverse()
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")
      |> blank_to_nil()

    {system_instruction, Enum.reverse(contents)}
  end

  defp gemini_role("assistant"), do: "model"
  defp gemini_role(_), do: "user"

  defp append_content([], _role, ""), do: []

  defp append_content(
         [%{"role" => role, "parts" => [%{"text" => existing_text}]} | rest],
         role,
         text
       ) do
    merged_text =
      [String.trim(existing_text), String.trim(text)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n\n")

    [%{"role" => role, "parts" => [%{"text" => merged_text}]} | rest]
  end

  defp append_content(contents, _role, ""), do: contents

  defp append_content(contents, role, text) do
    [%{"role" => role, "parts" => [%{"text" => text}]} | contents]
  end

  defp maybe_put_system_instruction(payload, nil), do: payload

  defp maybe_put_system_instruction(payload, system_instruction) do
    Map.put(payload, "system_instruction", %{
      "parts" => [%{"text" => system_instruction}]
    })
  end

  defp maybe_put_max_output_tokens(payload, nil), do: payload

  defp maybe_put_max_output_tokens(payload, max_output_tokens) do
    update_in(payload, ["generationConfig"], fn config ->
      Map.put(config || %{}, "maxOutputTokens", max_output_tokens)
    end)
  end

  defp extract_text(%{"candidates" => [%{"content" => %{"parts" => parts}} | _]})
       when is_list(parts) do
    text =
      parts
      |> Enum.flat_map(fn
        %{"text" => value} when is_binary(value) ->
          trimmed = String.trim(value)
          if trimmed == "", do: [], else: [trimmed]

        _ ->
          []
      end)
      |> Enum.join("\n\n")

    case blank_to_nil(text) do
      nil -> {:error, :empty_llm_response}
      normalized_text -> {:ok, normalized_text}
    end
  end

  defp extract_text(%{"promptFeedback" => prompt_feedback} = body) when is_map(prompt_feedback) do
    {:error, {:blocked_prompt, body}}
  end

  defp extract_text(body), do: {:error, {:invalid_response, body}}

  defp max_output_tokens(opts) do
    value =
      Keyword.get(
        opts,
        :max_tokens,
        System.get_env(
          "AUTOMATA_LLM_GEMINI_MAX_OUTPUT_TOKENS",
          Integer.to_string(@default_max_output_tokens)
        )
      )

    case value do
      number when is_integer(number) and number > 0 ->
        number

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {parsed, _} when parsed > 0 -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_model(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("models/")
    |> case do
      "" -> @default_model
      normalized -> normalized
    end
  end
end
