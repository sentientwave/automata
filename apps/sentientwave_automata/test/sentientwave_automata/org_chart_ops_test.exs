defmodule SentientwaveAutomata.OrgChartOpsTest do
  use SentientwaveAutomata.DataCase, async: true

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.AgentProfile
  alias SentientwaveAutomata.Agents.Tools.DestroyDepartment
  alias SentientwaveAutomata.Agents.Tools.OrgJobStatus
  alias SentientwaveAutomata.OrgChart
  alias SentientwaveAutomata.OrgChart.Ops

  defp insert_agent(lp, name, opts \\ %{}) do
    {:ok, _} =
      Agents.upsert_agent(%{
        slug: lp,
        kind: :agent,
        display_name: name,
        matrix_localpart: lp,
        status: :active,
        metadata: Map.get(opts, :metadata, %{}),
        company_description: "Example Org",
        job_description: "Serves the organization.",
        reports_to: Map.get(opts, :reports_to)
      })
  end

  describe "multi-step hire (inline fallback)" do
    test "runs all stages and completes the durable job" do
      insert_agent("ops.manager", "Ops Manager")

      args = %{
        "localpart" => "multi.hire",
        "display_name" => "Multi Hire",
        "title" => "Analyst",
        "department" => "Operations Department",
        "reports_to" => "ops.manager"
      }

      {:ok, job} = Ops.start("hire_agent", args, requested_by: "executive-assistant")
      assert job.status == "completed"
      assert job.workflow_id =~ "org_ops"

      result = job.result
      assert result["status"] == "ok"
      assert result["localpart"] == "multi.hire"
      assert result["generated_password"]

      assert %{"create_org_record" => _, "provision_matrix_membership" => _, "announce_hire" => _} =
               result["steps"]

      assert result["steps"]["provision_matrix_membership"]["status"] == "skipped"
      assert %AgentProfile{} = Agents.get_agent_by_localpart("multi.hire")
    end

    test "same op + args + requester maps onto the same workflow id (idempotency)" do
      insert_agent("dup.manager", "Dup Manager")

      args = %{
        "localpart" => "dup.hire",
        "display_name" => "Dup Hire",
        "title" => "Analyst",
        "department" => "Ops Department",
        "reports_to" => "dup.manager"
      }

      {:ok, first} = Ops.start("hire_agent", args, requested_by: "tester")
      {:ok, second} = Ops.start("hire_agent", args, requested_by: "tester")

      assert first.workflow_id == second.workflow_id
      # The retried call observes the ORIGINAL completed job instead of re-hiring.
      assert second.status == "completed"
      assert second.result["steps"]["create_org_record"]["hired"] == true
    end
  end

  describe "single-step ops" do
    test "fire_agent domain errors surface as failed jobs" do
      {:ok, job} = Ops.start("fire_agent", %{"localpart" => ""}, requested_by: "tester")

      assert job.status == "failed"
      assert job.error =~ "localpart"
    end

    test "set_reports_to updates reporting lines through a job" do
      insert_agent("rep.parent", "Rep Parent")
      insert_agent("rep.child", "Rep Child")

      {:ok, job} =
        Ops.start(
          "set_reports_to",
          %{"localpart" => "rep.child", "reports_to" => "rep.parent"},
          requested_by: "tester"
        )

      assert job.status == "completed"
      child = Agents.get_agent_by_localpart("rep.child")
      assert child.reports_to == "rep.parent"
    end

    test "assign_org_unit moves an agent through a job" do
      insert_agent("movable", "Movable Agent")

      {:ok, job} =
        Ops.start(
          "assign_org_unit",
          %{"localpart" => "movable", "department" => "New Dept"},
          requested_by: "tester"
        )

      assert job.status == "completed"
      agent = Agents.get_agent_by_localpart("movable")
      assert agent.metadata["department"] == "New Dept"
    end
  end

  describe "tools" do
    test "destroy_department with wait=true returns the result" do
      {:ok, _} = OrgChart.create_unit(%{"kind" => "department", "name" => "Doomed"})

      {:ok, result} = DestroyDepartment.call(%{"name" => "Doomed", "wait" => true})

      assert result["destroyed"] == true
      refute Enum.any?(OrgChart.list_units(), &(&1.name == "Doomed"))
    end

    test "destroy_department async returns a queued job then completes" do
      {:ok, _} = OrgChart.create_unit(%{"kind" => "department", "name" => "Async Doomed"})

      {:ok, queued} = DestroyDepartment.call(%{"name" => "Async Doomed"})
      assert queued["status"] in ["queued", "completed"]
      assert queued["job_id"] =~ "org_ops"

      {:ok, status} = OrgJobStatus.call(%{"job_id" => queued["job_id"]})
      assert status["op"] == "destroy_department"
      assert status["status"] == "completed"
      assert status["result"]["destroyed"] == true

      {:error, :unknown_job} = OrgJobStatus.execute_direct(%{"job_id" => "org_ops_nope"})
      {:error, :missing_job_id} = OrgJobStatus.execute_direct(%{})
    end

    test "unsupported ops are rejected" do
      assert_raise ArgumentError, ~r/unsupported org op/, fn ->
        Ops.start("world_domination", %{})
      end
    end
  end
end
