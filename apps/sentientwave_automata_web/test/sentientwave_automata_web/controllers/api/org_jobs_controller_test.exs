defmodule SentientwaveAutomataWeb.API.OrgJobsControllerTest do
  @moduledoc false
  use SentientwaveAutomataWeb.ConnCase

  alias SentientwaveAutomata.OrgChart.Job
  alias SentientwaveAutomata.Repo

  @token "org-jobs-test-token"

  setup do
    previous = System.get_env("AUTOMATA_API_TOKEN")
    System.put_env("AUTOMATA_API_TOKEN", @token)

    on_exit(fn ->
      if previous do
        System.put_env("AUTOMATA_API_TOKEN", previous)
      else
        System.delete_env("AUTOMATA_API_TOKEN")
      end
    end)

    :ok
  end

  defp authed(conn), do: put_req_header(conn, "authorization", "Bearer #{@token}")

  defp insert_job(attrs) do
    %Job{}
    |> Job.changeset(
      Map.put_new(attrs, :workflow_id, "org_ops_test_#{System.unique_integer([:positive])}")
    )
    |> Repo.insert!()
  end

  test "requires service auth when token is configured", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/org-jobs")
    assert json_response(conn, 401)["error"] == "service_auth_required"
  end

  test "validates a completed continuation via API", %{conn: conn} do
    job =
      insert_job(%{
        op: "create_team",
        requested_by: "alice",
        status: "completed",
        result: %{"status" => "ok", "created" => true, "name" => "Q3 Team"}
      })

    conn = conn |> authed() |> get(~p"/api/v1/org-jobs/#{job.workflow_id}")
    body = json_response(conn, 200)

    assert body["data"]["job_id"] == job.workflow_id
    assert body["data"]["status"] == "completed"
    assert body["data"]["completed?"] == true
    assert body["data"]["errored?"] == false
    assert body["data"]["result"]["status"] == "ok"
    assert body["data"]["op"] == "create_team"
    assert body["data"]["requested_by"] == "alice"
  end

  test "reports an errored continuation via API", %{conn: conn} do
    job =
      insert_job(%{
        op: "fire_agent",
        requested_by: "bob",
        status: "failed",
        error: "agent not found: ghost.agent"
      })

    conn = conn |> authed() |> get(~p"/api/v1/org-jobs/#{job.workflow_id}")
    body = json_response(conn, 200)

    assert body["data"]["status"] == "failed"
    assert body["data"]["errored?"] == true
    assert body["data"]["completed?"] == false
    assert body["data"]["error"] == "agent not found: ghost.agent"
  end

  test "returns 404 for an unknown job_id", %{conn: conn} do
    conn = conn |> authed() |> get(~p"/api/v1/org-jobs/org_ops_does_not_exist")
    assert json_response(conn, 404)["error"] == "not_found"
  end

  test "lists the most recent org jobs", %{conn: conn} do
    _ = insert_job(%{op: "create_team", status: "completed", result: %{"status" => "ok"}})
    _ = insert_job(%{op: "hire_agent", status: "running"})

    conn = conn |> authed() |> get(~p"/api/v1/org-jobs")
    body = json_response(conn, 200)

    assert is_list(body["data"])
    assert length(body["data"]) >= 2
    assert Enum.all?(body["data"], &is_map/1)
  end
end
