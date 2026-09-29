defmodule SentientwaveAutomata.Agents.Tools.OpsJob do
  @moduledoc """
  Shared dispatcher turning agent tool calls into async org/chat operation
  jobs (`OrgChart.Ops.start/3`) with optional synchronous completion.

  Default behavior is async: tools return `{status: queued, job_id}` and agents
  poll with the `org_job_status` tool. Setting `"wait": true` blocks until the
  job finishes and returns its result.
  """

  alias SentientwaveAutomata.OrgChart.Ops

  @wait_timeout_ms 120_000

  # Freshness-first ops: every call gets its own workflow + job row instead of
  # reusing the deterministic idempotency key, so repeated reads/status
  # checks/shell commands see current state rather than a cached result.
  @fresh_ops [
    "search_org_chart",
    "org_job_status",
    "system_directory_admin",
    "brave_search",
    "run_shell"
  ]

  @doc "The shared `wait` parameter added to every dispatched tool."
  def wait_param do
    %{
      "type" => "boolean",
      "description" =>
        "Set true to block until the operation completes and return its full result. " <>
          "Default false: returns a job id immediately; check progress with org_job_status."
    }
  end

  @doc """
  Dispatches `op` as an async job. Returns `{:ok, map}` or `{:error, term}`
  tagged with `error_tag` on failures.
  """
  def dispatch(op, args, opts, error_tag) when is_binary(op) and is_map(args) do
    agent_id = Keyword.get(opts, :agent_id)
    {wait?, tool_args} = Map.pop(args, "wait", false)
    tool_args = Map.put(tool_args, "agent_id", agent_id)

    start_opts =
      if op in @fresh_ops do
        [
          requested_by: agent_id && to_string(agent_id),
          idempotency_key: "#{op}_" <> (:rand.bytes(6) |> Base.encode16(case: :lower))
        ]
      else
        [requested_by: agent_id && to_string(agent_id)]
      end

    with {:ok, job} <- Ops.start(op, tool_args, start_opts) do
      if truthy?(wait?) do
        await(job, error_tag)
      else
        {:ok,
         %{
           "status" => "queued",
           "job_id" => job.workflow_id,
           "op" => job.op,
           "note" => "check progress with the org_job_status tool using this job_id"
         }}
      end
    end
  rescue
    e -> {:error, {error_tag, Exception.message(e)}}
  end

  defp await(job, error_tag) do
    case Ops.await(job, @wait_timeout_ms) do
      {:ok, %{status: "completed", result: result}} when is_map(result) ->
        {:ok, result}

      {:ok, %{status: "failed", error: error}} when is_binary(error) ->
        {:error, {error_tag, error}}

      {:ok, job} ->
        {:error, {error_tag, "job ended in status #{job.status}"}}

      {:error, :timeout} ->
        {:error, {error_tag, :timeout}}
    end
  end

  defp truthy?(value), do: value in [true, "true", "TRUE", "1", 1]
end
