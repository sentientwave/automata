defmodule SentientwaveAutomata.OrgChart.OpsWorkflow do
  @moduledoc """
  Temporal workflow for org-structure and Matrix chat operations requested by
  agents, executed as durable async jobs.

  Best-practice notes (per Temporal docs):
  - Workflow code is deterministic; every side effect lives in activities.
  - The caller-derived workflow_id is the idempotency key: redelivered tool
    calls reuse the same execution instead of duplicating work.
  - Multi-step operations (hire/fire) run each stage as its own activity so a
    failure resumes from that stage, and job progress reflects real state.
  - Job status is durably recorded by the workflow itself, so status queries
    never depend on this process being alive.
  """

  use TemporalSdk.Workflow

  @activity SentientwaveAutomata.OrgChart.OpsActivities

  @impl true
  # Tolerate over-wrapped inputs: workflows started by hand via tctl put the
  # whole JSON payload into a single payload, so an input meant as [op_map]
  # arrives wrapped in extra single-element lists. Unwrap one level at a
  # time (each recursion strictly reduces nesting, so this terminates) and
  # re-dispatch.
  def execute(context, [inner]) when is_list(inner), do: execute(context, inner)

  def execute(_context, [%{"op" => op, "args" => _args} = input]) do
    # Temporal's JSON externalizer decodes `null` as the :null atom.
    job_id = normalize_null_id(Map.get(input, "job_id") || Map.get(input, "workflow_id"))

    _ = activity("mark_running", %{"job_id" => job_id})

    result =
      case @activity.steps_for(op) do
        [] ->
          apply_op(input)

        steps ->
          run_multi_step(job_id, op, input["args"] || %{}, steps)
      end

    result = result || %{"status" => "error", "reason" => "no result"}

    _ = activity("record_result", %{"job_id" => job_id, "result" => result})

    result
  end

  # Catch-all for malformed input (e.g. a hand-started workflow whose payload
  # does not match the expected shape). Record the error on the job row when
  # one can be identified and let the workflow COMPLETE instead of
  # crash-looping on `function_clause` forever.
  def execute(_context, other) do
    first = if is_list(other), do: List.first(other), else: other

    job_id =
      if is_map(first),
        do: normalize_null_id(Map.get(first, "job_id") || Map.get(first, "workflow_id")),
        else: nil

    result = %{"status" => "error", "reason" => "malformed org ops input: #{inspect(other)}"}

    if is_binary(job_id) do
      _ = activity("record_result", %{"job_id" => job_id, "result" => result})
    end

    result
  end

  # Single-step operation.
  defp apply_op(input) do
    input
    |> Map.take(["op", "args"])
    |> Map.put("step", "apply_op")
    |> then(&activity("apply_op", &1))
  end

  # Multi-step operation (hire/fire): carry accumulated state through each
  # stage and record progress after every step for live status updates.
  defp run_multi_step(job_id, op, base_args, steps) do
    {ok?, facts, steps_result} =
      Enum.reduce(steps, {true, %{}, %{}}, fn
        _step, {false, facts, sr} ->
          {false, facts, sr}

        step, {true, facts, sr} ->
          result =
            activity("run_step", %{
              "op" => op,
              "step_name" => step,
              "state" => Map.merge(base_args, facts)
            })

          _ =
            activity("record_progress", %{
              "job_id" => job_id,
              "step_name" => step,
              "result" => result
            })

          sr = Map.put(sr, step, result)

          facts =
            Map.merge(
              facts,
              result |> Map.drop(["status", "warnings", "steps"]) |> stringify()
            )

          {result["status"] == "ok" or result["status"] == "skipped", facts, sr}
      end)
      |> then(fn {ok?, facts, sr} -> {ok?, facts, sr} end)

    if ok? do
      %{"status" => "ok"} |> Map.merge(facts) |> Map.put("steps", steps_result)
    else
      reason =
        Enum.find_value(steps_result, "operation failed", fn {step, result} ->
          if result["status"] == "error", do: "#{step}: #{result["reason"]}", else: nil
        end)

      %{"status" => "error", "reason" => reason} |> Map.put("steps", steps_result)
    end
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp activity(step, payload) do
    [%{result: result}] =
      wait_all([
        start_activity(
          @activity,
          [SentientwaveAutomata.Temporal.activity_payload(step, payload)],
          task_queue: SentientwaveAutomata.Temporal.activity_task_queue(),
          start_to_close_timeout: {15, :minute}
        )
      ])

    unwrap(result)
  end

  defp unwrap({:ok, [result]}), do: result
  defp unwrap({:ok, result}), do: result
  defp unwrap([result]), do: result
  defp unwrap(result), do: result

  defp normalize_null_id(:null), do: nil
  defp normalize_null_id(nil), do: nil
  defp normalize_null_id(value), do: value
end
