defmodule SentientwaveAutomataTemporal.Bootstrap do
  @moduledoc """
  Verifies Temporal availability and reconciles Temporal-owned workflow state.
  """

  use GenServer

  alias SentientwaveAutomata.Temporal
  require Logger

  @reconcile_interval_ms 30_000
  @verify_interval_ms 15_000
  @health_check_timeout_ms 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :verify_temporal)
    send(self(), :reconcile)
    {:ok, %{temporal_ready?: false}}
  end

  @impl true
  def handle_info(:verify_temporal, state) do
    next_state =
      case verify_temporal() do
        :ok ->
          if not state.temporal_ready? do
            Logger.info("temporal_bootstrap ready=true")
          end

          %{state | temporal_ready?: true}

        {:error, reason} ->
          Logger.warning("temporal_bootstrap ready=false reason=#{inspect(reason)}")
          %{state | temporal_ready?: false}
      end

    Process.send_after(self(), :verify_temporal, @verify_interval_ms)
    {:noreply, next_state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    Process.send_after(self(), :reconcile, @reconcile_interval_ms)
    {:noreply, state}
  end

  defp verify_temporal do
    case TemporalSdk.Cluster.is_started(Temporal.cluster()) do
      true -> verify_health_workflow()
      {:error, reason} -> {:error, {:cluster_not_started, reason}}
      other -> {:error, {:cluster_not_ready, other}}
    end
  end

  defp verify_health_workflow do
    health_workflow_id =
      Temporal.generated_workflow_id("temporal_healthcheck_#{node()}")

    try do
      case TemporalSdk.start_workflow(
             Temporal.cluster(),
             Temporal.workflow_task_queue(),
             SentientwaveAutomataTemporal.HealthWorkflow,
             namespace: Temporal.namespace(),
             workflow_id: health_workflow_id,
             wait: @health_check_timeout_ms,
             input: [%{"health" => true}],
             # see Adapters.Temporal.Runtime.start_temporal_workflow/3 for why
             opentelemetry: false
           ) do
        {response, result} when is_map(response) ->
          health_result(result)

        {:ok, _response, _awaited} ->
          :ok

        {:error, reason} ->
          {:error, {:health_workflow_failed, reason}}

        other ->
          {:error, {:health_workflow_unexpected, other}}
      end
    rescue
      error ->
        {:error, {:health_workflow_wait_failed, Exception.message(error)}}
    end
  end

  # `wait:` returns the workflow closing result: `{completed, value}` on success,
  # `{failed, details}` (or other closing status) when the workflow did not finish cleanly.
  defp health_result({:completed, _value}), do: :ok
  defp health_result({:failed, details}), do: {:error, {:health_workflow_failed, details}}

  defp health_result({status, details}),
    do: {:error, {:health_workflow_unexpected, {status, details}}}

  defp health_result(_value), do: :ok

  defp reconcile do
    run_if_exported(SentientwaveAutomata.Agents, :mark_orphaned_runs_failed, [])
    run_if_exported(SentientwaveAutomata.Agents.ScheduledTaskReconciler, :reconcile, [])
    run_if_exported(SentientwaveAutomata.Governance.Workflow, :reconcile_open_proposals, [])

    # Cross-store consistency sweep: heals directory/agents/matrix drift.
    # Throttled internally to at most one full sweep per 10 minutes.
    run_if_exported(SentientwaveAutomata.OrgChart.Consistency, :reconcile, [])
  rescue
    error ->
      Logger.warning("temporal_bootstrap reconcile_failed error=#{Exception.message(error)}")

      :ok
  end

  defp run_if_exported(module, function, args) do
    if function_exported?(module, function, length(args)) do
      apply(module, function, args)
    else
      :ok
    end
  end
end
