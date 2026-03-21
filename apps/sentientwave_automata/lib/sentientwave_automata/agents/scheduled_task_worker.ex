defmodule SentientwaveAutomata.Agents.ScheduledTaskWorker do
  @moduledoc """
  Polls due agent scheduled tasks and executes them.
  """

  use GenServer

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Durable
  require Logger

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    schedule_tick(initial_delay_ms())
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    process_due_tasks()
    schedule_tick(interval_ms())
    {:noreply, state}
  end

  defp process_due_tasks do
    Agents.list_due_scheduled_tasks(limit: batch_size())
    |> Enum.each(fn task ->
      case Agents.claim_scheduled_task(task) do
        {:ok, claimed_task} ->
          outcome = execute_task(claimed_task)
          _ = Agents.record_scheduled_task_result(claimed_task, outcome)

        {:error, _reason} ->
          :ok
      end
    end)
  end

  defp execute_task(task) do
    started_at = DateTime.utc_now()

    outcome =
      case task.task_type do
        :run_agent_prompt ->
          run_agent_prompt(task)

        :post_room_message ->
          post_room_message(task)
      end

    outcome
    |> Map.put("started_at", DateTime.to_iso8601(started_at))
    |> Map.put("finished_at", DateTime.utc_now() |> DateTime.to_iso8601())
  rescue
    error ->
      Logger.error(
        "scheduled_task execution_failed task_id=#{task.id} error=#{Exception.format(:error, error, __STACKTRACE__)}"
      )

      %{
        "status" => "error",
        "reason" => Exception.message(error),
        "kind" => "exception"
      }
  end

  defp run_agent_prompt(task) do
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
        %{
          "status" => "ok",
          "task_type" => "run_agent_prompt",
          "run_id" => run.id,
          "workflow_id" => run.workflow_id
        }

      {:error, reason} ->
        %{
          "status" => "error",
          "task_type" => "run_agent_prompt",
          "reason" => inspect(reason)
        }
    end
  end

  defp post_room_message(task) do
    room_id = task.room_id || ""
    message = task.message_body || ""

    case matrix_adapter().post_message(room_id, message, %{
           scheduled_task_id: task.id,
           agent_id: task.agent_id,
           kind: "scheduled_task_post"
         }) do
      :ok ->
        %{
          "status" => "ok",
          "task_type" => "post_room_message",
          "room_id" => room_id
        }

      {:error, reason} ->
        %{
          "status" => "error",
          "task_type" => "post_room_message",
          "room_id" => room_id,
          "reason" => inspect(reason)
        }
    end
  end

  defp schedule_tick(ms), do: Process.send_after(self(), :tick, ms)

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp batch_size do
    System.get_env("AUTOMATA_SCHEDULED_TASK_BATCH_SIZE", "10")
    |> String.to_integer()
  rescue
    _ -> 10
  end

  defp initial_delay_ms do
    System.get_env("AUTOMATA_SCHEDULED_TASK_INITIAL_DELAY_MS", "2000")
    |> String.to_integer()
  rescue
    _ -> 2_000
  end

  defp interval_ms do
    System.get_env("AUTOMATA_SCHEDULED_TASK_INTERVAL_MS", "15000")
    |> String.to_integer()
  rescue
    _ -> 15_000
  end
end
