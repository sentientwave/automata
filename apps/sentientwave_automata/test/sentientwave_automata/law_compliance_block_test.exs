defmodule SentientwaveAutomata.LawComplianceBlockTest do
  use SentientwaveAutomata.DataCase, async: true

  alias SentientwaveAutomata.Agents.LLM.Client
  alias SentientwaveAutomata.Agents.LawCompliance

  # Regression: LLM-authored block_message used to be echoed into chat verbatim
  # (internal verdicts like "Do not certify: ..." leaked as agent messages).
  test "blocked_response always returns the neutral fallback, never the LLM verdict" do
    certification = %{
      "certified" => false,
      "enforcement" => "blocked",
      "summary" => "response contradicts the principal's latest instruction",
      "violations" => ["contradicts instruction"],
      "block_message" =>
        "Do not certify: the response contradicts the principal's latest instruction"
    }

    refute LawCompliance.blocked_response(certification) =~ "Do not certify"
    assert LawCompliance.blocked_response(certification) == LawCompliance.blocked_response(%{})
  end

  # Regression: planner prompt embedded Elixir inspect output (%{name: ...}),
  # which models cannot reliably parse or act on.
  test "tool planner prompt embeds tools as strict JSON" do
    tools = [
      %{
        name: "send_matrix_message",
        description: "Send a Matrix message",
        parameters: %{"type" => "object", "properties" => %{}}
      }
    ]

    %{"content" => content} = Client.tool_planner_message(tools)

    refute content =~ "%{"
    assert content =~ ~s("name":"send_matrix_message")
    assert content =~ ~s({"tool_calls":[)
  end
end
