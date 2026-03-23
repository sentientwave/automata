defmodule SentientwaveAutomata.Orchestration.ConversationWorkflowTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Orchestration.Activities
  alias SentientwaveAutomata.Orchestration.Workflow

  setup do
    previous_matrix_adapter = Application.get_env(:sentientwave_automata, :matrix_adapter)

    Application.put_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.TestSupport.MatrixAdapterStub
    )

    on_exit(fn ->
      if previous_matrix_adapter do
        Application.put_env(:sentientwave_automata, :matrix_adapter, previous_matrix_adapter)
      else
        Application.delete_env(:sentientwave_automata, :matrix_adapter)
      end
    end)

    Process.put(:matrix_adapter_test_pid, self())
    :ok
  end

  describe "conversation workflow orchestration" do
    test "persists succeeded status and response result after the started-message activity" do
      workflow = insert_workflow()
      attrs = conversation_attrs()

      Process.put(:matrix_post_message_response, :ok)

      assert [posted] =
               Activities.execute(nil, [
                 %{
                   "step" => "post_started_message",
                   "workflow_id" => workflow.workflow_id,
                   "attrs" => attrs
                 }
               ])

      assert posted == %{"posted" => true, "room_id" => attrs["room_id"]}

      assert_receive {:matrix_post_message, room_id, message, metadata}
      assert room_id == attrs["room_id"]
      assert message == "Workflow started: #{attrs["objective"]}"
      assert metadata["workflow_id"] == workflow.workflow_id
      assert metadata["kind"] == "conversation_workflow_started"

      assert [%{"workflow_id" => ^workflow.workflow_id, "status" => "succeeded"}] =
               Activities.execute(nil, [
                 %{
                   "step" => "mark_status",
                   "workflow_id" => workflow.workflow_id,
                   "status" => "succeeded",
                   "result" => posted
                 }
               ])

      reloaded = Repo.get_by!(Workflow, workflow_id: workflow.workflow_id)
      assert reloaded.status == :succeeded
      assert reloaded.result == posted
      assert reloaded.error == %{}
    end

    test "classifies forbidden and not-in-room room-post failures as permanent failures" do
      workflow = insert_workflow()
      attrs = conversation_attrs()
      room_id = attrs["room_id"]

      for {status, errcode} <- [
            {403, "M_FORBIDDEN"},
            {404, "M_NOT_IN_ROOM"}
          ] do
        Process.put(
          :matrix_post_message_response,
          {:error,
           {:send_http_error, status, %{"errcode" => errcode, "error" => "room post failed"}}}
        )

        assert [posted] =
                 Activities.execute(nil, [
                   %{
                     "step" => "post_started_message",
                     "workflow_id" => workflow.workflow_id,
                     "attrs" => attrs
                   }
                 ])

        assert posted["posted"] == false
        assert posted["permanent_error"] == true
        assert posted["room_id"] == room_id

        assert posted["error"]["items"] == [
                 "send_http_error",
                 status,
                 %{"errcode" => errcode, "error" => "room post failed"}
               ]

        assert_receive {:matrix_post_message, ^room_id, _, _}
      end
    end

    test "mark_status accepts nested activity result payloads and stores a map" do
      workflow = insert_workflow()

      assert [%{"workflow_id" => ^workflow.workflow_id, "status" => "succeeded"}] =
               Activities.execute(nil, [
                 %{
                   "step" => "mark_status",
                   "workflow_id" => workflow.workflow_id,
                   "status" => "succeeded",
                   "result" => [
                     %{"posted" => true, "room_id" => workflow.room_id}
                   ]
                 }
               ])

      reloaded = Repo.get_by!(Workflow, workflow_id: workflow.workflow_id)
      assert reloaded.status == :succeeded
      assert reloaded.result == %{"posted" => true, "room_id" => workflow.room_id}
    end
  end

  defp insert_workflow do
    suffix = System.unique_integer([:positive])
    workflow_id = "wf-conversation-#{suffix}"

    %Workflow{}
    |> Workflow.changeset(%{
      workflow_id: workflow_id,
      status: :running,
      room_id: "!room:example.org",
      objective: "Draft release notes",
      requested_by: "@alice:example.org",
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp conversation_attrs do
    %{
      "room_id" => "!room:example.org",
      "objective" => "Draft release notes",
      "requested_by" => "@alice:example.org"
    }
  end
end
