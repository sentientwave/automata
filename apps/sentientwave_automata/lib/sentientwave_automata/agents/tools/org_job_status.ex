defmodule SentientwaveAutomata.Agents.Tools.OrgJobStatus do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.OrgChart.Jobs

  @impl true
  def name, do: "org_job_status"

  @impl true
  def description do
    "Check the status of an async org/chat operation job (hire, fire, department changes, " <>
      "Matrix room operations). Returns the current status and, when finished, the full result."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "job_id" => %{
          "type" => "string",
          "description" => "The job_id returned by the operation tool"
        }
      },
      "required" => ["job_id"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    args = if Map.has_key?(args, "wait"), do: args, else: Map.put(args, "wait", true)

    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "org_job_status",
      args,
      opts,
      :status_failed
    )
  end

  @doc "Direct (non-Temporal) execution used by org-ops activities and tests."
  def execute_direct(args, _opts \\ []) when is_map(args) do
    job_id = args |> Map.get("job_id", "") |> to_string() |> String.trim()

    cond do
      job_id == "" ->
        {:error, :missing_job_id}

      job = Jobs.get(job_id) ->
        payload =
          %{
            "status" => job.status,
            "op" => job.op,
            "job_id" => job.workflow_id,
            "requested_by" => job.requested_by
          }
          |> Map.merge(
            case job.status do
              "completed" -> %{"result" => stringify(job.result)}
              "failed" -> %{"error" => job.error}
              _ -> %{"current_step" => job.result && job.result["current_step"]}
            end
          )

        {:ok, payload}

      true ->
        {:error, :unknown_job}
    end
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify(other), do: other
end
