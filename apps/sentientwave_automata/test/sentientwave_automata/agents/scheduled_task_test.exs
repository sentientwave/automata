defmodule SentientwaveAutomata.Agents.ScheduledTaskTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.ScheduledTask
  alias SentientwaveAutomata.Repo

  test "creates and updates scheduled tasks for agents" do
    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: "scheduler-agent",
               kind: :agent,
               display_name: "Scheduler Agent",
               matrix_localpart: "scheduler-agent",
               status: :active
             })

    assert {:ok, task} =
             Agents.create_scheduled_task(agent.id, %{
               "name" => "Morning Prompt",
               "enabled" => "true",
               "task_type" => "run_agent_prompt",
               "schedule_type" => "daily",
               "schedule_interval" => "1",
               "schedule_hour" => "9",
               "schedule_minute" => "15",
               "timezone" => "Etc/UTC",
               "prompt_body" => "Share the daily update"
             })

    assert task.task_type == :run_agent_prompt
    assert task.schedule_type == :daily
    assert task.next_run_at

    assert {:ok, updated_task} =
             Agents.update_scheduled_task(task, %{
               "schedule_type" => "weekly",
               "schedule_interval" => "2",
               "schedule_weekday" => "5",
               "schedule_hour" => "14",
               "schedule_minute" => "30"
             })

    assert updated_task.schedule_type == :weekly
    assert updated_task.schedule_weekday == 5
    assert updated_task.schedule_interval == 2
  end

  test "lists due tasks, claims them, and records outcomes" do
    assert {:ok, agent} =
             Agents.upsert_agent(%{
               slug: "due-agent",
               kind: :agent,
               display_name: "Due Agent",
               matrix_localpart: "due-agent",
               status: :active
             })

    assert {:ok, task} =
             Agents.create_scheduled_task(agent.id, %{
               "name" => "Heartbeat",
               "enabled" => "true",
               "task_type" => "post_room_message",
               "schedule_type" => "hourly",
               "schedule_interval" => "1",
               "schedule_minute" => "5",
               "timezone" => "Etc/UTC",
               "room_id" => "!ops:localhost",
               "message_body" => "Still alive"
             })

    past = DateTime.add(DateTime.utc_now(), -300, :second)

    assert {1, _} =
             from(t in ScheduledTask, where: t.id == ^task.id)
             |> Repo.update_all(set: [next_run_at: past])

    [due_task] = Agents.list_due_scheduled_tasks(now: DateTime.utc_now(), limit: 5)
    assert due_task.id == task.id

    assert {:ok, claimed_task} = Agents.claim_scheduled_task(due_task)
    assert DateTime.compare(claimed_task.next_run_at, DateTime.utc_now()) == :gt

    assert {:ok, recorded_task} =
             Agents.record_scheduled_task_result(claimed_task, %{
               "status" => "ok",
               "task_type" => "post_room_message"
             })

    assert recorded_task.last_run_at
    assert recorded_task.last_outcome["status"] == "ok"

    assert {:ok, disabled_task} = Agents.set_scheduled_task_enabled(recorded_task, false)
    assert disabled_task.enabled == false
    assert disabled_task.next_run_at == nil
  end
end
