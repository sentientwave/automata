defmodule SentientwaveAutomata.Agents.LLM.Providers.Local do
  @moduledoc false

  @behaviour SentientwaveAutomata.Agents.LLMProvider

  @impl true
  def complete(messages, _opts \\ []) when is_list(messages) do
    user_text =
      messages
      |> Enum.reverse()
      |> Enum.find_value("", fn
        %{"role" => "user", "content" => content} when is_binary(content) -> content
        _ -> nil
      end)
      |> String.trim()

    reply =
      if user_text == "" do
        "I am ready. Ask me to summarize, plan, or propose next steps."
      else
        "I received your request: \"#{user_text}\"."
      end

    {:ok, reply}
  end
end
