defmodule SentientwaveAutomata.Agents.Tools.SendMatrixMessageTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Tools.SendMatrixMessage
  alias SentientwaveAutomata.Matrix.Directory

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

    _ =
      Directory.upsert_user(
        %{
          localpart: "jane.doe",
          kind: :agent,
          display_name: "Jane Doe",
          password: "password-12345",
          admin: false,
          metadata: %{}
        },
        seed: true
      )

    {:ok, agent} =
      Agents.upsert_agent(%{
        slug: "john.smith",
        kind: :agent,
        display_name: "John Smith",
        matrix_localpart: "john.smith",
        status: :active,
        metadata: %{"title" => "Head of Risk & Insurance"}
      })

    {:ok, _wallet} =
      Agents.upsert_agent_wallet(agent.id, %{
        kind: "personal",
        status: "active",
        matrix_credentials: %{
          "localpart" => "john.smith",
          "mxid" => "@john.smith:localhost",
          "password" => "secret-pass"
        }
      })

    %{agent: agent}
  end

  test "sends to an explicit room id under the agent's own account", %{agent: agent} do
    assert {:ok, result} =
             SendMatrixMessage.call(
               %{"room_id" => "!risk:localhost", "body" => "Renewal update posted."},
               agent_id: agent.id
             )

    assert result["status"] == "sent"
    assert result["room_id"] == "!risk:localhost"

    assert_receive {:matrix_post_message_as, room_id, message, credentials, _metadata}
    assert room_id == "!risk:localhost"
    assert message == "Renewal update posted."
    assert credentials["localpart"] == "john.smith"
  end

  test "direct message resolves a DM room and mentions the colleague", %{agent: agent} do
    Process.put(:matrix_direct_room, "!dm-jane:localhost")

    assert {:ok, result} =
             SendMatrixMessage.call(
               %{"to" => "jane.doe", "body" => "Please review the report."},
               agent_id: agent.id
             )

    assert result["status"] == "sent"
    assert result["room_id"] == "!dm-jane:localhost"
    assert result["to"] == "jane.doe"

    assert_receive {:matrix_resolve_direct_room, "jane.doe"}
    assert_receive {:matrix_post_message_as, room_id, message, credentials, _metadata}
    assert room_id == "!dm-jane:localhost"
    assert message == "@jane.doe Please review the report."
    assert credentials["localpart"] == "john.smith"
  end

  test "does not duplicate the mention when the body already mentions the colleague", %{
    agent: agent
  } do
    assert {:ok, result} =
             SendMatrixMessage.call(
               %{"to" => "jane.doe", "body" => "@jane.doe:localhost thanks!"},
               agent_id: agent.id
             )

    assert result["body"] == "@jane.doe:localhost thanks!"
  end

  test "rejects calls without a body or without a target", %{agent: agent} do
    assert {:error, :missing_body} =
             SendMatrixMessage.execute_direct(
               %{"to" => "jane.doe", "body" => "  "},
               agent_id: agent.id
             )

    assert {:error, :missing_room_or_recipient} =
             SendMatrixMessage.execute_direct(%{"body" => "hello"}, agent_id: agent.id)
  end

  test "rejects when the agent has no wallet", %{agent: agent} do
    {:ok, other} =
      Agents.upsert_agent(%{
        slug: "no.wallet.agent",
        kind: :agent,
        display_name: "No Wallet",
        matrix_localpart: "no.wallet.agent",
        status: :active,
        metadata: %{}
      })

    assert {:error, :no_agent_wallet} =
             SendMatrixMessage.execute_direct(%{"room_id" => "!x:localhost", "body" => "hi"},
               agent_id: other.id
             )

    assert {:ok, _} =
             SendMatrixMessage.call(%{"room_id" => "!x:localhost", "body" => "hi"},
               agent_id: agent.id
             )
  end
end

defmodule SentientwaveAutomata.Tools.SendMatrixMessageAliasesTest do
  use SentientwaveAutomata.DataCase, async: true

  alias SentientwaveAutomata.Agents.Tools.SendMatrixMessage

  test "accepts message/localpart aliases", %{} do
    {:ok, agent} =
      SentientwaveAutomata.Agents.upsert_agent(%{
        slug: "alias.agent",
        kind: :agent,
        display_name: "Alias Agent",
        matrix_localpart: "alias.agent",
        status: :active,
        metadata: %{},
        company_description: "Example",
        job_description: "Serves."
      })

    # alias keys resolve: "message" becomes body and "localpart" becomes the
    # recipient. The recipient lookup runs after body validation, so hitting
    # :unknown_recipient (rather than :missing_body) proves both aliases worked.
    assert {:error, {:unknown_recipient, "carol"}} =
             SendMatrixMessage.execute_direct(
               %{"localpart" => "carol", "message" => "hello"},
               agent_id: agent.id
             )

    # wrong-style keys still fail at recipient resolution (alias NOT applied)
    assert {:error, {:unknown_recipient, "someone"}} =
             SendMatrixMessage.execute_direct(
               %{"to" => "someone", "body" => "hello"},
               agent_id: agent.id
             )

    assert {:error, :missing_body} =
             SendMatrixMessage.execute_direct(%{"to" => "someone"}, agent_id: agent.id)
  end
end
