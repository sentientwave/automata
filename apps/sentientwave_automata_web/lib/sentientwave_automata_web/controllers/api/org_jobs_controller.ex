defmodule SentientwaveAutomataWeb.API.OrgJobsController do
  @moduledoc """
  Read-only API for validating org-operation continuations.

  Org control tools dispatch a dedicated durable Temporal workflow
  (`OrgChart.OpsWorkflow`) and return a `job_id` continuation. This endpoint
  lets an API client check, without touching data directly, whether that
  operation has completed or errored, and read its result/error.
  """
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.OrgChart.Jobs

  @doc """
  `GET /api/v1/org-jobs` — most recent org-operation jobs (newest first).

  Optional `limit` query param (default 50, max 200).
  """
  def index(conn, params) do
    limit = params |> Map.get("limit", "50") |> to_string() |> parse_limit()
    jobs = Jobs.list(limit) |> Enum.map(&payload/1)
    json(conn, %{data: jobs})
  end

  defp parse_limit(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> min(n, 200)
      _ -> 50
    end
  end

  @doc """
  `GET /api/v1/org-jobs/:job_id` — validate a single continuation.

  Returns the job's `status` (`queued` | `running` | `completed` | `failed`)
  plus, when finished, its `result` (on `completed`) or `error` (on
  `failed`). `404` when the `job_id` is unknown.
  """
  def show(conn, %{"job_id" => job_id}) do
    case Jobs.get(job_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: :not_found})

      job ->
        json(conn, %{data: payload(job)})
    end
  end

  defp payload(job) do
    %{
      "job_id" => job.workflow_id,
      "op" => job.op,
      "status" => job.status,
      "completed?" => job.status == "completed",
      "errored?" => job.status == "failed",
      "requested_by" => job.requested_by,
      "result" => job.result,
      "error" => job.error,
      "inserted_at" => job.inserted_at,
      "updated_at" => job.updated_at
    }
  end
end
