defmodule SentientwaveAutomata.OrchestratorTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Orchestrator

  describe "start_workflow/1" do
    test "starts workflow for community edition" do
      assert {:ok, workflow} =
               Orchestrator.start_workflow(%{
                 room_id: "!room:example.org",
                 objective: "Draft release notes",
                 requested_by: "@alice:example.org",
                 edition: :community
               })

      assert workflow.status == :running
      assert workflow.room_id == "!room:example.org"
    end

    test "returns feature_not_enabled for enterprise-only capabilities" do
      refute SentientwaveAutomata.Policy.Entitlements.allowed?(:sso, %{edition: :community})
      assert SentientwaveAutomata.Policy.Entitlements.allowed?(:sso, %{edition: :enterprise})
    end

    test "rejects invalid payload" do
      assert {:error, :invalid_payload} =
               Orchestrator.start_workflow(%{
                 room_id: "",
                 objective: "",
                 requested_by: ""
               })
    end
  end
end
