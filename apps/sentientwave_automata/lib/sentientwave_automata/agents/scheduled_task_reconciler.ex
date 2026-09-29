defmodule SentientwaveAutomata.Agents.ScheduledTaskReconciler do
  @moduledoc """
  Control-plane reconciler that ensures persisted scheduled tasks are mirrored
  into Temporal-managed scheduler workflows.
  """

  use GenServer

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.ScheduledTask
  alias SentientwaveAutomata.Temporal
  require Logger

  @reconcile_interval_ms 30_000
  # B11: the reconciler used to send a "refresh" signal to EVERY enabled task
  # every 30s even when nothing changed. Each signal interrupts the workflow's
  # pending timer, reloads state and rewrites history (~2,880 events/task/day
  # of pure churn in Temporal/YB history storage). Tasks are now only signalled
  # when their fingerprint actually changed.
  @state_key {__MODULE__, :task_fingerprints}

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def reconcile do
    state = :persistent_term.get(@state_key, %{})

    enabled_by_id =
      Agents.list_enabled_scheduled_tasks()
      |> Map.new(&{&1.id, &1})

    Enum.each(enabled_by_id, fn {_id, task} ->
      ensure_task_workflow(task, state)
    end)

    fingerprints = Map.new(enabled_by_id, fn {id, t} -> {id, task_fingerprint(t)} end)
    :persistent_term.put(@state_key, fingerprints)

    Agents.list_temporal_managed_scheduled_tasks()
    |> Enum.reject(&Map.has_key?(enabled_by_id, &1.id))
    |> Enum.each(fn task ->
      if is_binary(task.workflow_id) and task.workflow_id != "" do
        _ = temporal_adapter().signal_workflow(task.workflow_id, "stop", %{"task_id" => task.id})
      end
    end)

    :ok
  end

  @impl true
  def init(state) do
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    reconcile()
    Process.send_after(self(), :reconcile, @reconcile_interval_ms)
    {:noreply, state}
  end

  # Fields whose change the workflow must observe (schedule, prompt, enabled).
  defp task_fingerprint(%ScheduledTask{} = task) do
    {task.schedule_type, task.schedule_interval, task.schedule_hour, task.schedule_minute,
     task.schedule_weekday, task.timezone, task.prompt_body, task.message_body, task.enabled,
     task.next_run_at, task.updated_at}
  end

  defp ensure_task_workflow(%ScheduledTask{} = task, state) do
    desired_workflow_id = Temporal.child_workflow_id("scheduled_task", task.id)

    cond do
      task.workflow_id in [nil, ""] ->
        case temporal_adapter().start_workflow("scheduled_task_workflow", %{
               workflow_id: desired_workflow_id,
               task_id: task.id
             }) do
          {:ok, %{workflow_id: workflow_id, run_id: run_id}} ->
            _ =
              Agents.update_scheduled_task_temporal_state(task, %{
                workflow_id: workflow_id,
                temporal_run_id: run_id
              })

            :ok

          {:error, reason} ->
            Logger.warning(
              "scheduled_task_reconcile_start_failed task_id=#{task.id} reason=#{inspect(reason)}"
            )

            :ok
        end

      true ->
        if Map.get(state, task.id) == task_fingerprint(task) do
          :ok
        else
          _ =
            temporal_adapter().signal_workflow(task.workflow_id, "refresh", %{
              "task_id" => task.id
            })

          :ok
        end
    end
  end

  defp temporal_adapter do
    Application.get_env(
      :sentientwave_automata,
      :temporal_adapter,
      SentientwaveAutomata.Adapters.Temporal.Runtime
    )
  end
end
