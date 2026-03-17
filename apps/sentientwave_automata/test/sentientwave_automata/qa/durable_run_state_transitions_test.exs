defmodule SentientwaveAutomata.QA.DurableRunStateTransitionsTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Orchestrator

  @moduletag :qa_skeleton

  describe "durable run state transitions" do
    test "new workflow starts in :running and is persisted in store" do
      assert {:ok, workflow} =
               Orchestrator.start_workflow(%{
                 room_id: "!qa:example.org",
                 objective: "QA transition check",
                 requested_by: "@qa:example.org",
                 edition: :community
               })

      assert workflow.status == :running
      assert is_binary(workflow.workflow_id)
      assert is_binary(workflow.run_id)

      stored = Orchestrator.list_workflows()
      assert Enum.any?(stored, &(&1.workflow_id == workflow.workflow_id))
    end

    @tag :skip
    test "run transitions running -> completed when temporal completion event is received" do
      # Planned API shape (to implement):
      # :ok = SentientwaveAutomata.Orchestration.RunState.handle_event(workflow_id, :completed)
      # run = SentientwaveAutomata.Orchestration.RunState.fetch!(workflow_id)
      #
      # Key assertions:
      # assert run.status == :completed
      # assert run.completed_at != nil
    end

    @tag :skip
    test "run transitions running -> failed when non-retryable activity error occurs" do
      # Planned API shape (to implement):
      # :ok = SentientwaveAutomata.Orchestration.RunState.handle_event(workflow_id, {:failed, :non_retryable})
      # run = SentientwaveAutomata.Orchestration.RunState.fetch!(workflow_id)
      #
      # Key assertions:
      # assert run.status == :failed
      # assert run.failure_reason == :non_retryable
    end
  end
end
