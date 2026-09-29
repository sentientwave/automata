defmodule SentientwaveAutomata.OrgChart.Ops do
  @moduledoc """
  Async, job-oriented entry point used by agent-facing org/chat tools.

  Every operation is a durable `SentientwaveAutomata.OrgChart.OpsWorkflow`
  Temporal workflow tracked by an `OrgChart.Job` row:

  - `start/3` returns immediately with the queued job (async job API).
  - `get_job/1` / `await/2` provide status updates and results.
  - The workflow_id is derived deterministically from op+args+requester
    (Temporal best practice: workflow id as idempotency key), so redelivered
    tool calls reuse the same execution and job row.
  - Dispatch to Temporal is **mandatory in production**: when the cluster is
    unavailable, `start/3` fails the job row and raises
    `SentientwaveAutomata.OrgChart.TemporalUnavailableError` so the tool call
    surfaces a clean error instead of silently mutating data inline.
  - When `require_temporal?/0` is false (dev/test by default), the same
    activity logic executes inline instead and the job completes synchronously;
    the result is tagged `"via" => "inline"`.
  """

  alias SentientwaveAutomata.OrgChart.Jobs
  alias SentientwaveAutomata.OrgChart.OpsActivities
  alias SentientwaveAutomata.OrgChart.TemporalUnavailableError
  alias SentientwaveAutomata.Temporal

  require Logger

  @wait_poll_ms 500

  def supported_ops, do: OpsActivities.supported_ops()

  @doc """
  True when org ops must be dispatched to a Temporal workflow (no inline
  fallback). Production-strict by default: enabled in `:prod`, disabled in
  `:dev`/`:test` unless `AUTOMATA_ORG_OPS_REQUIRE_TEMPORAL` overrides it.
  """
  def require_temporal? do
    Application.get_env(:sentientwave_automata, :org_ops_require_temporal, false)
  end

  @doc """
  Starts an operation as an async job and returns `{:ok, job}` immediately.

  Options:
    - `:requested_by` — agent slug/localpart (part of the idempotency key)
    - `:idempotency_key` — optional explicit key overriding op+args hashing
  """
  @spec start(String.t(), map(), keyword()) :: {:ok, SentientwaveAutomata.OrgChart.Job.t()}
  def start(op, args, opts \\ []) when is_binary(op) and is_map(args) do
    unless op in supported_ops() do
      raise ArgumentError, "unsupported org op: #{inspect(op)}"
    end

    requested_by = Keyword.get(opts, :requested_by)
    args = normalize_args(args)

    workflow_id =
      Temporal.child_workflow_id(
        "org_ops",
        Keyword.get(opts, :idempotency_key) || op_key(op, args, requested_by)
      )

    {:ok, job} =
      Jobs.create_or_get(%{
        workflow_id: workflow_id,
        op: op,
        args: args,
        requested_by: requested_by && to_string(requested_by)
      })

    input = %{"op" => op, "args" => args, "job_id" => workflow_id}

    case start_temporal(workflow_id, input) do
      :ok ->
        {:ok, job}

      {:error, reason} ->
        if require_temporal?() do
          Jobs.fail(workflow_id, "temporal_unavailable: #{inspect(reason)}")

          raise %TemporalUnavailableError{
            id: workflow_id,
            op: op,
            reason: reason
          }
        else
          Logger.warning(
            "org_ops_temporal_unavailable id=#{workflow_id} falling_back_to_inline=true"
          )

          run_inline(input, workflow_id)
          {:ok, Jobs.get(workflow_id)}
        end
    end
  end

  @doc "Fetches a job with status/result by workflow_id (or binary id)."
  @spec get_job(String.t()) :: SentientwaveAutomata.OrgChart.Job.t() | nil
  def get_job(job_id), do: Jobs.get(job_id)

  @doc """
  Polls the job store until the job leaves queued/running or `timeout_ms`
  elapses (Temporal best practice: poll durable state, not processes).
  """
  @spec await(SentientwaveAutomata.OrgChart.Job.t() | String.t(), non_neg_integer()) ::
          {:ok, SentientwaveAutomata.OrgChart.Job.t()} | {:error, :timeout}
  def await(job, timeout_ms \\ 60_000)

  def await(%SentientwaveAutomata.OrgChart.Job{} = job, timeout_ms),
    do: await(job.workflow_id, timeout_ms)

  def await(job_id, timeout_ms) when is_binary(job_id) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_await(job_id, deadline)
  end

  # Backward-compatible synchronous helper (start + await).
  @spec run(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(op, args, opts \\ []) do
    with {:ok, job} <- start(op, args, opts) do
      case await(job, Keyword.get(opts, :timeout_ms, 60_000)) do
        {:ok, job} -> job_result(job)
        {:error, :timeout} -> {:error, :timeout}
      end
    end
  end

  defp do_await(job_id, deadline) do
    cond do
      (job = Jobs.get(job_id)) && job.status in ["completed", "failed"] ->
        {:ok, job}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :timeout}

      true ->
        Process.sleep(@wait_poll_ms)
        do_await(job_id, deadline)
    end
  end

  defp job_result(%{status: "completed", result: result}) when is_map(result),
    do: {:ok, result}

  defp job_result(%{status: "failed", error: error}) when is_binary(error),
    do: {:error, error}

  defp job_result(job), do: {:ok, %{"status" => job.status}}

  defp start_temporal(workflow_id, input) do
    case TemporalSdk.Cluster.is_started(Temporal.cluster()) do
      true ->
        try do
          case TemporalSdk.start_workflow(
                 Temporal.cluster(),
                 Temporal.workflow_task_queue(),
                 SentientwaveAutomata.OrgChart.OpsWorkflow,
                 namespace: Temporal.namespace(),
                 workflow_id: workflow_id,
                 input: [input]
               ) do
            {:ok, _response} ->
              :ok

            {:ok, _response, _awaited} ->
              :ok

            {status, _} when status in [:completed, :failed] ->
              :ok

            {:error, reason} ->
              Logger.warning("org_ops_start_failed id=#{workflow_id} reason=#{inspect(reason)}")
              {:error, :temporal_unavailable}

            other ->
              Logger.warning(
                "org_ops_unexpected_response id=#{workflow_id} got=#{inspect(other)}"
              )

              {:error, :temporal_unavailable}
          end
        rescue
          error ->
            Logger.warning(
              "org_ops_start_raised id=#{workflow_id} error=#{Exception.message(error)}"
            )

            {:error, :temporal_unavailable}
        end

      _ ->
        {:error, :temporal_unavailable}
    end
  end

  defp run_inline(%{"op" => op, "args" => args}, workflow_id) do
    _ = Jobs.mark_running(workflow_id)

    result = OpsActivities.run_all_steps(op, args)

    case result do
      %{"status" => "error"} -> Jobs.fail(workflow_id, result["reason"] || inspect(result))
      _ -> Jobs.complete(workflow_id, Map.merge(stringify(result), %{"via" => "inline"}))
    end

    :ok
  end

  # Deterministic per (op + normalized args + requester): the same logical
  # operation always maps onto the same workflow id and job row.
  defp op_key(op, args, requested_by) do
    :crypto.hash(:sha256, "#{requested_by}:#{op}:#{Jason.encode!(args)}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp normalize_args(args) when is_map(args),
    do: args |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Enum.sort() |> Map.new()
end
