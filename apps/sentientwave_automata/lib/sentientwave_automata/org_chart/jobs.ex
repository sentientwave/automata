defmodule SentientwaveAutomata.OrgChart.Jobs do
  @moduledoc """
  Durable job records for org/chat operations executed as Temporal workflows.

  The Temporal workflow_id is the idempotency key: retries of the same logical
  operation reuse the same job row instead of duplicating side effects.
  """

  import Ecto.Query

  alias SentientwaveAutomata.OrgChart.Job
  alias SentientwaveAutomata.Repo

  @doc """
  Creates the job for a workflow_id, or returns the existing row unchanged so
  redelivered/retried tool calls observe the original job instead of duplicating.
  """
  @spec create_or_get(map()) :: {:ok, Job.t()}
  def create_or_get(attrs) when is_map(attrs) do
    workflow_id = Map.fetch!(attrs, :workflow_id)

    case Repo.get_by(Job, workflow_id: workflow_id) do
      %Job{} = job ->
        {:ok, job}

      nil ->
        %Job{}
        |> Job.changeset(Map.put(attrs, :status, "queued"))
        |> put_masked_args()
        |> Repo.insert()
        |> case do
          {:ok, job} -> {:ok, job}
          # Lost an insert race: the winner's row IS this operation's job.
          {:error, _} -> {:ok, Repo.get_by!(Job, workflow_id: workflow_id)}
        end
    end
  end

  # Tools like brave_search carry their configured API token inside the job
  # args (the durable activity cannot read process opts). The workflow input
  # keeps the real token; the persisted row (readable via the org-jobs API)
  # only records that one was present.
  defp put_masked_args(changeset) do
    case Map.get(changeset.changes, :args) do
      args when is_map(args) ->
        case Map.get(args, "api_token") do
          token when is_binary(token) and token != "" ->
            Ecto.Changeset.put_change(changeset, :args, Map.put(args, "api_token", "***"))

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end

  @doc "Marks the job running (best-effort; safe to call repeatedly)."
  @spec mark_running(String.t()) :: :ok
  def mark_running(workflow_id) do
    from(j in Job, where: j.workflow_id == ^workflow_id and j.status == "queued")
    |> Repo.update_all(set: [status: "running", updated_at: now()])

    :ok
  end

  @doc "Records the successful result (idempotent: completed jobs stay closed)."
  @spec complete(String.t(), map()) :: :ok
  def complete(workflow_id, result) when is_map(result) do
    from(j in Job,
      where: j.workflow_id == ^workflow_id and j.status in ["queued", "running"]
    )
    |> Repo.update_all(set: [status: "completed", result: result, updated_at: now()])

    :ok
  end

  @doc """
  Records step-level progress for a running multi-step operation (e.g. hire /
  fire): merges `info` under `result.progress` and stamps `current_step`.
  """
  @spec progress(String.t(), String.t(), map()) :: :ok
  def progress(workflow_id, step, info \\ %{}) when is_binary(step) and is_map(info) do
    case Repo.get_by(Job, workflow_id: workflow_id) do
      %Job{} = job ->
        result = job.result || %{}
        previous = Map.get(result, "progress", [])

        entry =
          %{"step" => step, "status" => info["status"]}
          |> Map.merge(Map.drop(info, ["status"]))

        updated =
          result
          |> Map.put("current_step", step)
          |> Map.put("progress", List.wrap(previous) ++ [entry])

        job
        |> Job.changeset(%{status: "running", result: updated})
        |> Repo.update()

        :ok

      nil ->
        :ok
    end
  end

  @doc "Records a failure (idempotent)."
  @spec fail(String.t(), String.t()) :: :ok
  def fail(workflow_id, error) when is_binary(error) do
    from(j in Job,
      where: j.workflow_id == ^workflow_id and j.status in ["queued", "running"]
    )
    |> Repo.update_all(set: [status: "failed", error: error, updated_at: now()])

    :ok
  end

  @doc "Fetches a job by workflow_id (or binary id)."
  @spec get(String.t()) :: Job.t() | nil
  def get(job_id) when is_binary(job_id) do
    case Repo.get_by(Job, workflow_id: job_id) do
      %Job{} = job ->
        job

      nil ->
        if uuid?(job_id), do: Repo.get(Job, job_id), else: nil
    end
  end

  @doc "Lists the most recent org-operation jobs (newest first)."
  @spec list(pos_integer()) :: [Job.t()]
  def list(limit \\ 50) when is_integer(limit) and limit > 0 do
    from(j in Job, order_by: [desc: j.inserted_at], limit: ^limit)
    |> Repo.all()
  end

  defp uuid?(value) do
    match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
