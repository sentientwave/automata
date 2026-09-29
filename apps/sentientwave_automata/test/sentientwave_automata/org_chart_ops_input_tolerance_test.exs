defmodule SentientwaveAutomata.OrgChartOpsInputToleranceTest do
  @moduledoc """
  Regression tests for hand-started (tctl) or otherwise malformed org-ops
  workflow inputs.

  Before these, `OpsWorkflow.execute/2` had a single matching clause, so a
  double-wrapped payload (`[[%{...}]]` instead of `[%{...}]`) raised
  `function_clause` and crash-looped the workflow task forever (seen live at
  ~670 retries for `org_ops_deploy_verify_create`).
  """
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.OrgChart.OpsActivities
  alias SentientwaveAutomata.OrgChart.OpsWorkflow

  describe "OpsWorkflow input tolerance" do
    test "double-wrapped input is unwrapped instead of raising function_clause" do
      # Inner map lacks "args", so after unwrapping it lands in the
      # malformed-input catch-all instead of executing the op.
      result = OpsWorkflow.execute(nil, [[%{"op" => "create_department"}]])

      assert %{"status" => "error", "reason" => reason} = result
      assert reason =~ "malformed org ops input"
    end

    test "triple-wrapped input (tctl -i whole-payload shape) is unwrapped too" do
      # tctl puts the whole JSON into one payload; the SDK then hands the
      # workflow the payload list, so [op_map] arrives as [[[op_map]]].
      result = OpsWorkflow.execute(nil, [[[%{"op" => "create_department"}]]])

      assert %{"status" => "error", "reason" => reason} = result
      assert reason =~ "malformed org ops input"
    end

    test "map input without op/args completes with an error result" do
      result = OpsWorkflow.execute(nil, [%{"foo" => 1}])

      assert %{"status" => "error"} = result
      assert result["reason"] =~ "malformed org ops input"
    end

    test "non-map input completes with an error result" do
      result = OpsWorkflow.execute(nil, ["garbage"])
      assert %{"status" => "error"} = result

      result = OpsWorkflow.execute(nil, 42)
      assert %{"status" => "error"} = result
    end
  end

  describe "OpsActivities without a job row (nil job_id)" do
    test "mark_running is a no-op" do
      assert [%{"status" => "running"}] =
               OpsActivities.execute(nil, [%{"step" => "mark_running", "job_id" => nil}])
    end

    test "record_result is a no-op" do
      assert [%{"status" => "recorded"}] =
               OpsActivities.execute(nil, [
                 %{"step" => "record_result", "job_id" => nil, "result" => %{"status" => "ok"}}
               ])
    end
  end

  describe "OpsActivities without a job row (Temporal :null job_id)" do
    # Temporal's JSON externalizer decodes a JSON null job_id as the :null
    # atom, not Elixir nil. Before the fix, mark_running fell through to the
    # unsupported-payload catch-all, which is non-retryable, so hand-started
    # workflows crash-looped on WorkflowTaskFailed forever.

    test "mark_running is a no-op for :null" do
      assert [%{"status" => "running"}] =
               OpsActivities.execute(nil, [%{"step" => "mark_running", "job_id" => :null}])
    end

    test "record_result is a no-op for :null" do
      assert [%{"status" => "recorded"}] =
               OpsActivities.execute(nil, [
                 %{"step" => "record_result", "job_id" => :null, "result" => %{"status" => "ok"}}
               ])
    end

    test "record_progress is a no-op for :null" do
      assert [%{"status" => "progressing"}] =
               OpsActivities.execute(nil, [
                 %{
                   "step" => "record_progress",
                   "job_id" => :null,
                   "step_name" => "ensure_department",
                   "result" => %{"status" => "ok"}
                 }
               ])
    end

    test "malformed input with :null job_id completes with an error result" do
      # The catch-all normalizes :null (no binary job_id to record on) and
      # completes with an error instead of crash-looping.
      result = OpsWorkflow.execute(nil, [%{"job_id" => :null, "weird" => true}])

      assert %{"status" => "error", "reason" => reason} = result
      assert reason =~ "malformed org ops input"
    end
  end
end
