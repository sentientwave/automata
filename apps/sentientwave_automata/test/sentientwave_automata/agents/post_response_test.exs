defmodule SentientwaveAutomata.Agents.PostResponseTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Activities

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
    Process.put(:matrix_post_message_response, :ok)

    {:ok, agent} =
      Agents.upsert_agent(%{
        slug: "john.smith",
        kind: :agent,
        display_name: "John Smith",
        matrix_localpart: "john.smith",
        status: :active,
        metadata: %{"title" => "Head of Risk & Insurance"}
      })

    {:ok, run} =
      Agents.create_run(%{
        agent_id: agent.id,
        workflow_id: "wf-post-#{System.unique_integer([:positive])}",
        status: :running,
        metadata: %{}
      })

    %{agent: agent, run: run}
  end

  test "posts under the agent's own account when the wallet has credentials", %{
    agent: agent,
    run: run
  } do
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

    attrs = %{"room_id" => "!risk:localhost"}

    assert :ok == Activities.post_response(run, attrs, "Renewal is on track.")

    assert_receive {:matrix_post_message_as, room_id, message, credentials, metadata}
    assert room_id == "!risk:localhost"
    assert message == "Renewal is on track."
    assert credentials["localpart"] == "john.smith"
    assert metadata[:run_id] == run.id

    refute_receive {:matrix_post_message, _, _, _}
  end

  test "falls back to the bot connection with a name label when no wallet", %{
    run: run
  } do
    attrs = %{"room_id" => "!risk:localhost"}

    assert :ok == Activities.post_response(run, attrs, "Renewal is on track.")

    assert_receive {:matrix_post_message, room_id, message, metadata}
    assert room_id == "!risk:localhost"
    assert message == "John Smith (Head of Risk & Insurance): Renewal is on track."
    assert metadata[:run_id] == run.id

    refute_receive {:matrix_post_message_as, _, _, _, _}
  end

  test "agent_post_credentials returns nil for missing or inactive wallets", %{agent: agent} do
    assert Activities.agent_post_credentials(nil) == nil
    assert Activities.agent_post_credentials(agent.id) == nil

    {:ok, _wallet} =
      Agents.upsert_agent_wallet(agent.id, %{
        kind: "personal",
        status: "disabled",
        matrix_credentials: %{"localpart" => "john.smith", "password" => "secret-pass"}
      })

    assert Activities.agent_post_credentials(agent.id) == nil
  end
end
