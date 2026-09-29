defmodule SentientwaveAutomata.Agents.Tools.ToolExecutionResilienceTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents.LLM.Client

  test "a failing tool call is recorded as a result, not surfaced as a run error" do
    # search_org_chart with no query/localpart fails its org-ops job with
    # :missing_query. It must become a visible tool result so the synthesizer
    # can react and the Temporal activity does not raise and retry forever.
    assert {:ok,
            [
              %{
                "name" => "search_org_chart",
                "result" => %{"error" => "{:search_failed, \"missing_query\"}"}
              }
            ]} =
             Client.execute_tool_calls(nil, [
               %{"name" => "search_org_chart", "arguments" => %{}}
             ])
  end

  test "a successful tool call still returns its result" do
    assert {:ok, results} =
             Client.execute_tool_calls(nil, [
               %{"name" => "search_org_chart", "arguments" => %{"query" => "nobody"}}
             ])

    assert [%{"name" => "search_org_chart", "result" => result}] = results
    assert is_map(result)
  end
end
