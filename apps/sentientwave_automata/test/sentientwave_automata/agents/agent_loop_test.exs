defmodule SentientwaveAutomata.Agents.AgentLoopTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.AgentLoop

  @base %{round: 1, tool_calls_so_far: 0, max_rounds: 8, max_tool_calls: 100}

  test "empty plan on round 1 means respond without tools" do
    decision = AgentLoop.next_action(Map.merge(@base, %{plan: []}))
    assert decision.action == :done
    assert decision.reason == "planner_complete"
  end

  test "empty plan after work means the task is complete" do
    decision =
      AgentLoop.next_action(Map.merge(@base, %{round: 4, tool_calls_so_far: 7, plan: []}))

    assert decision.action == :done
    assert decision.reason == "planner_complete"
    assert decision.rounds_used == 3
  end

  test "executes a non-empty plan" do
    plan = [%{"name" => "hire_agent", "arguments" => %{"localpart" => "a.b"}}]

    decision = AgentLoop.next_action(Map.merge(@base, %{plan: plan}))

    assert decision.action == :execute_plan
    assert decision.plan == plan
  end

  test "tool budget stops the loop even with a pending plan" do
    decision =
      AgentLoop.next_action(
        Map.merge(@base, %{
          plan: [%{"name" => "search_org_chart", "arguments" => %{}}],
          tool_calls_so_far: 100,
          max_tool_calls: 100
        })
      )

    assert decision.action == :done
    assert decision.reason == "tool_budget"
  end

  test "round budget stops the loop" do
    decision =
      AgentLoop.next_action(
        Map.merge(@base, %{
          plan: [%{"name" => "search_org_chart", "arguments" => %{}}],
          round: 25,
          max_rounds: 24
        })
      )

    assert decision.action == :done
    assert decision.reason == "round_budget"
  end

  test "no-progress guard fires when the same plan repeats too many times" do
    plan = [%{"name" => "search_org_chart", "arguments" => %{"query" => "x"}}]

    first = AgentLoop.next_action(Map.merge(@base, %{plan: plan}))
    assert first.action == :execute_plan

    still_progressing =
      AgentLoop.next_action(
        Map.merge(@base, %{
          plan: plan,
          fingerprint: AgentLoop.fingerprint(plan),
          streak: 2
        })
      )

    assert still_progressing.action == :execute_plan

    stuck =
      Map.merge(@base, %{
        plan: plan,
        fingerprint: AgentLoop.fingerprint(plan),
        streak: 3
      })

    decision = AgentLoop.next_action(stuck)
    assert decision.action == :done
    assert decision.reason == "no_progress"
  end

  test "fingerprint is order-insensitive per batch but differs across calls" do
    a = AgentLoop.fingerprint([%{"name" => "a", "arguments" => %{"x" => 1}}, %{"name" => "b"}])
    b = AgentLoop.fingerprint([%{"name" => "b"}, %{"name" => "a", "arguments" => %{"x" => 1}}])
    c = AgentLoop.fingerprint([%{"name" => "a", "arguments" => %{"x" => 1}}])

    assert a == b
    assert a != c
  end

  test "fingerprint is a JSON-safe hex string" do
    fp = AgentLoop.fingerprint([%{"name" => "a", "arguments" => %{"x" => 1}}])

    assert is_binary(fp)
    assert byte_size(fp) == 32
    assert Regex.match?(~r/^[0-9a-f]{32}$/, fp)

    # Regression: raw MD5 bytes hit invalid-UTF-8 bytes when `agent_runs.result`
    # is written to jsonb, raising Jason.EncodeError and crash-looping the
    # workflow. Hex encoding round-trips cleanly through Jason.
    assert Jason.decode!(Jason.encode!(%{"fingerprint" => fp})) == %{"fingerprint" => fp}
  end
end
