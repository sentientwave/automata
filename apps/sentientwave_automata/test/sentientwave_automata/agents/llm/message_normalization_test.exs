defmodule SentientwaveAutomata.Agents.LLM.MessageNormalizationTest do
  @moduledoc """
  Verifies that system messages are merged into a single leading message
  before being sent to providers (required by chat templates such as Qwen3
  via llama.cpp, which raise "System message must be at the beginning"
  otherwise).
  """
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.LLM.Client

  defp normalize(messages), do: Client.normalize_messages(messages)

  test "merges multiple system messages into one leading message" do
    messages = [
      %{"role" => "system", "content" => "You are Ops Lead."},
      %{"role" => "system", "content" => "Constitution follows."},
      %{"role" => "user", "content" => "hi"},
      %{"role" => "system", "content" => "Tool results: ..."}
    ]

    assert normalize(messages) == [
             %{
               "role" => "system",
               "content" => "You are Ops Lead.\n\nConstitution follows.\n\nTool results: ..."
             },
             %{"role" => "user", "content" => "hi"}
           ]
  end

  test "leaves messages without system messages untouched" do
    messages = [%{"role" => "user", "content" => "hi"}]
    assert normalize(messages) == messages
  end

  test "keeps a single leading system message as-is" do
    messages = [
      %{"role" => "system", "content" => "You are Ops Lead."},
      %{"role" => "user", "content" => "hi"}
    ]

    assert normalize(messages) == messages
  end
end
