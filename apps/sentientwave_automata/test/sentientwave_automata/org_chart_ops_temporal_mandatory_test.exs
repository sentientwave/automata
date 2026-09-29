defmodule SentientwaveAutomata.OrgChartOpsTemporalMandatoryTest do
  @moduledoc """
  Verifies the mandatory-Temporal contract for org ops:

  - When `org_ops_require_temporal` is true and Temporal is unavailable,
    `Ops.start/3` raises `TemporalUnavailableError` and the job row is marked
    `failed` (no silent inline data mutation).
  - When `org_ops_require_temporal` is false, the op falls back to inline
    execution and completes synchronously (`via: "inline"`).
  """
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.OrgChart.{Jobs, Ops, TemporalUnavailableError}

  setup do
    original = Application.get_env(:sentientwave_automata, :org_ops_require_temporal)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:sentientwave_automata, :org_ops_require_temporal)
        value -> Application.put_env(:sentientwave_automata, :org_ops_require_temporal, value)
      end
    end)

    :ok
  end

  test "mandatory: raises TemporalUnavailableError and fails the job when Temporal is down" do
    Application.put_env(:sentientwave_automata, :org_ops_require_temporal, true)

    error =
      try do
        {:ok, _} =
          Ops.start("create_team", %{"name" => "Mandatory Team #{:os.system_time(:second)}"},
            requested_by: "tester"
          )

        flunk("expected TemporalUnavailableError to be raised")
      rescue
        e in TemporalUnavailableError -> e
      end

    assert error.id =~ "org_ops"
    assert error.op == "create_team"

    job = Jobs.get(error.id)
    assert job.status == "failed"
    assert job.error =~ "temporal_unavailable"
  end

  test "non-mandatory: falls back to inline and completes synchronously" do
    Application.put_env(:sentientwave_automata, :org_ops_require_temporal, false)

    {:ok, job} =
      Ops.start("create_team", %{"name" => "Inline Team #{:os.system_time(:second)}"},
        requested_by: "tester"
      )

    assert job.status == "completed"
    assert (job.result || %{})["via"] == "inline"
  end
end
