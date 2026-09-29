defmodule SentientwaveAutomata.OrgOpsAllToolsTest do
  @moduledoc """
  Every agent tool dispatches a dedicated Temporal workflow (no direct data
  access) and returns a continuation (job_id) validatable via the API.
  """
  use SentientwaveAutomata.DataCase, async: true

  alias SentientwaveAutomata.Agents.Tools.BraveSearch
  alias SentientwaveAutomata.Agents.Tools.OrgChart
  alias SentientwaveAutomata.Agents.Tools.OrgJobStatus
  alias SentientwaveAutomata.Agents.Tools.RunShell
  alias SentientwaveAutomata.Agents.Tools.Registry
  alias SentientwaveAutomata.Agents.Tools.SystemDirectoryAdmin
  alias SentientwaveAutomata.OrgChart.Job
  alias SentientwaveAutomata.OrgChart.OpsActivities
  alias SentientwaveAutomata.Repo

  import Ecto.Query

  defp latest_jobs(op) do
    from(j in Job, where: j.op == ^op, order_by: [desc: j.inserted_at])
    |> Repo.all()
  end

  test "every registered tool has a dedicated org-ops workflow op" do
    ops = OpsActivities.supported_ops()

    for tool <- Registry.list_supported() do
      assert tool in ops, "tool #{tool} has no dedicated org-ops workflow op"
    end
  end

  test "search_org_chart dispatches a job and returns the result" do
    {:ok, result} = OrgChart.call(%{"view" => "people"})

    assert result["view"] == "people"
    assert is_list(result["people"])

    [job | _] = latest_jobs("search_org_chart")
    assert job.status == "completed"
    assert job.result["view"] == "people"
  end

  test "search_org_chart is freshness-first: identical calls create distinct jobs" do
    {:ok, _} = OrgChart.call(%{"view" => "units"})
    {:ok, _} = OrgChart.call(%{"view" => "units"})

    jobs = latest_jobs("search_org_chart")
    assert length(jobs) >= 2
    assert Enum.uniq(Enum.map(jobs, & &1.workflow_id)) == Enum.map(jobs, & &1.workflow_id)
  end

  test "org_job_status dispatches a job and reports the target job" do
    {:ok, _} = OrgChart.call(%{"view" => "units"})
    target = latest_jobs("search_org_chart") |> hd()

    {:ok, status} = OrgJobStatus.call(%{"job_id" => target.workflow_id})
    assert status["op"] == "search_org_chart"
    assert status["status"] == "completed"
  end

  test "system_directory_admin dispatches a job and lists users" do
    {:ok, result} = SystemDirectoryAdmin.call(%{"action" => "list_directory"})
    assert is_list(result["users"])
    assert result["count"] == length(result["users"])
  end

  test "run_shell dispatches a job and returns command output" do
    {:ok, result} = RunShell.call(%{"command" => "echo ops-shell-ok", "cwd" => System.tmp_dir!()})

    assert result["exit_code"] == 0
    assert result["stdout"] =~ "ops-shell-ok"
  end

  test "brave_search without a token fails the job cleanly" do
    assert {:error, {:search_failed, "missing_api_token"}} =
             BraveSearch.call(%{"query" => "some query"})

    [job | _] = latest_jobs("brave_search")
    assert job.status == "failed"
  end
end
