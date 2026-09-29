defmodule SentientwaveAutomata.Agents.AgentLoop do
  @moduledoc """
  Configuration and stop-condition policy for the iterative agentic tool loop.

  Best practices applied (Temporal durable agents + loop engineering):
  - the loop lives in the workflow (deterministic); every LLM call and tool
    batch is an activity, so retries resume from the failed round;
  - bounded iterations: max tool rounds and max total tool calls;
  - no-progress detection: identical consecutive plans force a stop;
  - empty plan means the model considers the task complete.
  """

  @max_rounds_hard_cap 100
  @max_tool_calls_hard_cap 500

  def max_tool_rounds do
    # Bulk operations (e.g. org-wide cleanup) legitimately need many rounds;
    # the binding budgets are total tool calls and the no-progress guard.
    "AUTOMATA_AGENT_MAX_TOOL_ROUNDS"
    |> int_env(24)
    |> min(@max_rounds_hard_cap)
    |> max(1)
  end

  def max_tool_calls do
    "AUTOMATA_AGENT_MAX_TOOL_CALLS"
    |> int_env(100)
    |> min(@max_tool_calls_hard_cap)
    |> max(1)
  end

  # A plan repeated this many consecutive times means the model is stuck;
  # stop instead of burning budget (loop-engineering no-progress guard).
  def max_repeated_plans, do: 3

  # Per planning round cap: models sometimes batch very large plans; execute
  # at most this many calls per round (the total budget still applies).
  def max_tool_calls_per_round do
    "AUTOMATA_AGENT_MAX_TOOL_CALLS_PER_ROUND"
    |> int_env(10)
    |> min(@max_rounds_hard_cap * 10)
    |> max(1)
  end

  @doc """
  Decides what the loop should do next. Pure function over the round summary,
  kept public for tests.
  """
  def next_action(summary) do
    plan = Map.get(summary, :plan, [])
    round = Map.get(summary, :round, 1)
    calls = Map.get(summary, :tool_calls_so_far, 0)
    max_calls = Map.get(summary, :max_tool_calls, max_tool_calls())
    max_rounds = Map.get(summary, :max_rounds, max_tool_rounds())
    max_repeats = Map.get(summary, :max_repeated_plans, max_repeated_plans())
    fingerprint = Map.get(summary, :fingerprint)
    streak = Map.get(summary, :streak, 0)

    cond do
      plan == [] ->
        %{action: :done, reason: "planner_complete", rounds_used: max(round - 1, 0)}

      calls >= max_calls ->
        %{action: :done, reason: "tool_budget", rounds_used: round}

      round > max_rounds ->
        %{action: :done, reason: "round_budget", rounds_used: max_rounds}

      is_binary(fingerprint) and streak >= max_repeats ->
        %{action: :done, reason: "no_progress", rounds_used: round, fingerprint: fingerprint}

      true ->
        %{action: :execute_plan, plan: plan, fingerprint: fingerprint}
    end
  end

  @doc """
  Fingerprint of a planned batch of calls, for no-progress detection.

  Hex-encoded (not raw MD5 bytes) so the value stays JSON-safe when it
  lands in `agent_runs.result` jsonb via Jason — raw 0x80+ bytes used to
  raise `Jason.EncodeError` and crash-loop the whole workflow.
  """
  def fingerprint(plan) when is_list(plan) do
    :crypto.hash(:md5, Jason.encode!(normalize(plan)))
    |> Base.encode16(case: :lower)
  end

  defp normalize(plan) do
    plan
    |> Enum.map(fn call ->
      name = call["name"] || call[:name] || ""
      args = call["arguments"] || call[:arguments] || %{}

      %{name: to_string(name), arguments: stringify(args)}
    end)
    |> Enum.sort_by(&{&1.name, Jason.encode!(&1.arguments)})
  end

  defp stringify(args) when is_map(args),
    do: args |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Enum.sort() |> Map.new()

  defp stringify(other), do: other

  defp int_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, _} -> int
          :error -> default
        end
    end
  end
end
