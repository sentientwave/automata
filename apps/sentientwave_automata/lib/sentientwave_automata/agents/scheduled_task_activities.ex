defmodule SentientwaveAutomata.Agents.ScheduledTaskActivities do
  @moduledoc """
  Temporal activity entrypoint for scheduled task workflows.
  """

  use TemporalSdk.Activity

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Durable
  alias SentientwaveAutomata.Agents.ScheduledTask

  @impl true
  def execute(_context, [%{"step" => "load_task_state", "task_id" => task_id}]) do
    case Agents.get_scheduled_task(task_id) do
      nil -> [%{"state" => "missing", "task_id" => task_id}]
      %ScheduledTask{} = task -> [serialize_task(task)]
    end
  end

  def execute(_context, [%{"step" => "execute_task", "task_id" => task_id}]) do
    case Agents.get_scheduled_task(task_id) do
      nil ->
        [%{"status" => "missing"}]

      %ScheduledTask{} = task ->
        execute_task(task)
    end
  end

  def execute(_context, [payload]) do
    fail_non_retryable(
      "scheduled_task.unsupported_step",
      "unsupported scheduled task activity step: #{inspect(payload)}"
    )
  end

  defp execute_task(%ScheduledTask{} = task) do
    case Agents.claim_scheduled_task(task) do
      {:ok, claimed_task} ->
        {outcome, failure_reason} = do_execute_task(claimed_task)

        _task =
          unwrap_result!(
            Agents.record_scheduled_task_result(claimed_task, outcome),
            "record scheduled task result"
          )

        case failure_reason do
          nil -> [outcome]
          reason -> raise "scheduled task execution failed: #{inspect(reason)}"
        end

      {:error, :stale} ->
        [%{"status" => "stale"}]

      {:error, reason} ->
        raise "failed to claim scheduled task: #{inspect(reason)}"
    end
  end

  defp do_execute_task(%ScheduledTask{task_type: :run_agent_prompt} = task) do
    agent = task.agent
    room_id = task.room_id || ""

    sender_mxid =
      "@#{agent.matrix_localpart}:#{System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")}"

    attrs = %{
      agent_id: task.agent_id,
      room_id: room_id,
      requested_by: sender_mxid,
      conversation_scope: if(room_id != "", do: "room", else: "unknown"),
      input: %{
        body: task.prompt_body || "",
        sender_mxid: sender_mxid,
        conversation_scope: if(room_id != "", do: "room", else: "unknown")
      },
      metadata: %{
        agent_slug: agent.slug,
        source: "scheduled_task",
        scheduled_task_id: task.id,
        scheduled_task_type: "run_agent_prompt"
      }
    }

    case Durable.start_run(attrs) do
      {:ok, run} ->
        {
          %{
            "status" => "ok",
            "task_type" => "run_agent_prompt",
            "run_id" => run.id,
            "workflow_id" => run.workflow_id
          },
          nil
        }

      {:error, reason} ->
        {
          %{
            "status" => "error",
            "task_type" => "run_agent_prompt",
            "reason" => inspect(reason)
          },
          reason
        }
    end
  end

  defp do_execute_task(%ScheduledTask{task_type: :post_room_message} = task) do
    case matrix_adapter().post_message(task.room_id || "", task.message_body || "", %{
           scheduled_task_id: task.id,
           agent_id: task.agent_id,
           kind: "scheduled_task_post"
         }) do
      :ok ->
        {
          %{
            "status" => "ok",
            "task_type" => "post_room_message",
            "room_id" => task.room_id || ""
          },
          nil
        }

      {:error, reason} ->
        {
          %{
            "status" => "error",
            "task_type" => "post_room_message",
            "room_id" => task.room_id || "",
            "reason" => inspect(reason)
          },
          reason
        }
    end
  end

  defp do_execute_task(%ScheduledTask{} = task) do
    fail_non_retryable(
      "scheduled_task.unsupported_task_type",
      "unsupported scheduled task type: #{inspect(task.task_type)}"
    )
  end

  defp serialize_task(%ScheduledTask{} = task) do
    %{
      "state" => "present",
      "task_id" => task.id,
      "enabled" => task.enabled,
      "workflow_id" => task.workflow_id,
      "next_run_at" => task.next_run_at && DateTime.to_iso8601(task.next_run_at),
      "wait_ms" => wait_ms(task.next_run_at)
    }
  end

  defp wait_ms(nil), do: 0

  defp wait_ms(%DateTime{} = next_run_at) do
    diff = DateTime.diff(next_run_at, DateTime.utc_now(), :millisecond)
    max(diff, 0)
  end

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp unwrap_result!({:ok, result}, _action), do: result

  defp unwrap_result!({:error, reason}, action) do
    raise "#{action} failed: #{inspect(reason)}"
  end

  defp unwrap_result!(result, _action), do: result

  defp fail_non_retryable(type, message) do
    fail(message: message, type: type, non_retryable: true)
  end
end
