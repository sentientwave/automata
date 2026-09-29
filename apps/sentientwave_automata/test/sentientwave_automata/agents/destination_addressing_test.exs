defmodule SentientwaveAutomata.Agents.DestinationAddressingTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Activities
  alias SentientwaveAutomata.Agents.MentionDispatcher
  alias SentientwaveAutomata.Agents.MentionRouter
  alias SentientwaveAutomata.Matrix.Directory

  setup do
    previous = System.get_env("AUTOMATA_ROOM_AUTONOMY_ENABLED")
    System.put_env("AUTOMATA_ROOM_AUTONOMY_ENABLED", "true")

    on_exit(fn ->
      if previous,
        do: System.put_env("AUTOMATA_ROOM_AUTONOMY_ENABLED", previous),
        else: System.delete_env("AUTOMATA_ROOM_AUTONOMY_ENABLED")
    end)

    for {lp, name} <- [{"john.smith", "John Smith"}, {"jane.doe", "Jane Doe"}] do
      _ =
        Directory.upsert_user(
          %{
            localpart: lp,
            kind: :agent,
            display_name: name,
            password: "password-12345",
            admin: false,
            metadata: %{}
          },
          seed: true
        )
    end

    %{}
  end

  test "a message with a destination mentions only that agent" do
    # person message mentioning jane → only jane runs (john ignores)
    assert {:ok, %{target_count: 1, run_ids: [run_id]}} =
             MentionDispatcher.dispatch(%{
               room_id: "!common:localhost",
               sender_mxid: "@boss:localhost",
               message_id: "msg-dest-#{System.unique_integer([:positive])}",
               body: "@jane.doe please update the report status"
             })

    run = Agents.get_run(run_id)
    assert Agents.get_agent(run.agent_id).slug == "jane.doe"
  end

  test "a message addressing an agent by leading name runs only that agent" do
    assert {:ok, %{target_count: 1, run_ids: [run_id]}} =
             MentionDispatcher.dispatch(%{
               room_id: "!common:localhost",
               sender_mxid: "@boss:localhost",
               message_id: "msg-leading-#{System.unique_integer([:positive])}",
               body: "jane.doe, could you send me the premium impact numbers?"
             })

    run = Agents.get_run(run_id)
    assert Agents.get_agent(run.agent_id).slug == "jane.doe"
  end

  test "an addressed message stays in room history for other agents" do
    body = "jane.doe, could you send me the premium impact numbers?"
    message_id = "msg-history-#{System.unique_integer([:positive])}"

    assert {:ok, %{target_count: 1}} =
             MentionDispatcher.dispatch(%{
               room_id: "!common:localhost",
               sender_mxid: "@boss:localhost",
               message_id: message_id,
               body: body
             })

    # The addressed message is persisted and remains visible to another agent
    # that is triggered later in the same room.
    assert %{body: ^body} = Agents.get_mention_by_message_id(message_id)
  end

  test "a message mentioning only a person starts no agent runs" do
    assert {:error, :no_agent_mentioned} =
             MentionDispatcher.dispatch(%{
               room_id: "!common:localhost",
               sender_mxid: "@nadia.anderson:localhost",
               message_id: "msg-person-dest-#{System.unique_integer([:positive])}",
               body: "@boss heads-up: memo is ready"
             })
  end

  test "address_sender prepends the sender's mention when the agent was explicitly mentioned" do
    run = %SentientwaveAutomata.Agents.Run{
      id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      metadata: %{"explicitly_mentioned" => true}
    }

    attrs = %{"requested_by" => "@boss:localhost"}

    assert Activities.address_sender("The memo is ready.", run, attrs) ==
             "@boss The memo is ready."

    # does not duplicate an existing mention
    assert Activities.address_sender("@boss the memo is ready.", run, attrs) ==
             "@boss the memo is ready."
  end

  test "address_sender leaves the reply untouched when not explicitly mentioned" do
    run = %SentientwaveAutomata.Agents.Run{
      id: Ecto.UUID.generate(),
      agent_id: Ecto.UUID.generate(),
      metadata: %{}
    }

    attrs = %{"requested_by" => "@boss:localhost"}
    assert Activities.address_sender("The memo is ready.", run, attrs) == "The memo is ready."
  end

  test "an @-pill mention (m.mentions) runs only the pill-targeted agent" do
    raw_event = %{
      "type" => "m.room.message",
      "sender" => "@boss:localhost",
      "event_id" => "pill-event-1",
      "content" => %{
        "msgtype" => "m.text",
        "body" => "Jane Doe: hi",
        "format" => "org.matrix.custom.html",
        "formatted_body" =>
          "<a href=\"https://matrix.to/#/@jane.doe:localhost\">Jane Doe</a>: hi",
        "m.mentions" => %{"user_ids" => ["@jane.doe:localhost"]}
      }
    }

    assert {:ok, %{target_count: 1, run_ids: [run_id]}} =
             MentionDispatcher.dispatch(%{
               room_id: "!common:localhost",
               sender_mxid: "@boss:localhost",
               message_id: "msg-pill-#{System.unique_integer([:positive])}",
               body: "Jane Doe: hi",
               raw_event: raw_event
             })

    run = Agents.get_run(run_id)
    assert Agents.get_agent(run.agent_id).slug == "jane.doe"
  end

  test "a matrix.to link without m.mentions still resolves the pill target" do
    raw_event = %{
      "type" => "m.room.message",
      "sender" => "@boss:localhost",
      "event_id" => "pill-event-2",
      "content" => %{
        "msgtype" => "m.text",
        "body" => "Jane Doe: please update the report",
        "format" => "org.matrix.custom.html",
        "formatted_body" =>
          "<a href=\"https://matrix.to/#/@jane.doe:localhost\">Jane Doe</a>: please update the report"
      }
    }

    assert {:ok, %{target_count: 1, run_ids: [run_id]}} =
             MentionDispatcher.dispatch(%{
               room_id: "!common:localhost",
               sender_mxid: "@boss:localhost",
               message_id: "msg-pill-link-#{System.unique_integer([:positive])}",
               body: "Jane Doe: please update the report",
               raw_event: raw_event
             })

    run = Agents.get_run(run_id)
    assert Agents.get_agent(run.agent_id).slug == "jane.doe"
  end

  test "a pill mentioning only a person starts no agent runs" do
    raw_event = %{
      "type" => "m.room.message",
      "sender" => "@nadia.anderson:localhost",
      "event_id" => "pill-event-3",
      "content" => %{
        "msgtype" => "m.text",
        "body" => "Boss: heads-up, memo is ready",
        "format" => "org.matrix.custom.html",
        "formatted_body" =>
          "<a href=\"https://matrix.to/#/@boss:localhost\">Boss</a>: heads-up, memo is ready",
        "m.mentions" => %{"user_ids" => ["@boss:localhost"]}
      }
    }

    assert {:error, :no_agent_mentioned} =
             MentionDispatcher.dispatch(%{
               room_id: "!common:localhost",
               sender_mxid: "@nadia.anderson:localhost",
               message_id: "msg-pill-person-#{System.unique_integer([:positive])}",
               body: "Boss: heads-up, memo is ready",
               raw_event: raw_event
             })
  end

  test "extract_pill_localparts reads m.mentions and matrix.to links" do
    raw_event = %{
      "content" => %{
        "body" => "Jane Doe: hi",
        "formatted_body" =>
          "<a href=\"https://matrix.to/#/@jane.doe:localhost\">Jane Doe</a>: hi",
        "m.mentions" => %{"user_ids" => ["@jane.doe:localhost", "@boss:localhost"]}
      }
    }

    assert MentionRouter.extract_pill_localparts(raw_event) ==
             ["jane.doe", "boss"]

    assert MentionRouter.extract_pill_localparts(nil) == []
    assert MentionRouter.extract_pill_localparts(%{}) == []
  end
end

defmodule SentientwaveAutomata.Agents.MentionedAnyoneTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.MentionRouter

  test "true for @mentions" do
    assert MentionRouter.mentioned_anyone?("@jane.doe please confirm")
    assert MentionRouter.mentioned_anyone?("please confirm @jane.doe:localhost thanks")
  end

  test "false for leading names and plain text" do
    refute MentionRouter.mentioned_anyone?("Team, quick status check please.")
    refute MentionRouter.mentioned_anyone?("Status check, everyone.")
    refute MentionRouter.mentioned_anyone?("Alex please confirm.")
  end
end

defmodule SentientwaveAutomata.Agents.AddressedAnyoneTest do
  use ExUnit.Case, async: true

  alias SentientwaveAutomata.Agents.MentionRouter

  test "true for @mentions and for leading names that resolved to an agent" do
    assert MentionRouter.addressed_anyone?("@jane.doe please confirm", [])

    assert MentionRouter.addressed_anyone?("jane.doe, please confirm", [%{slug: "jane.doe"}])
  end

  test "false for non-agent leading words and plain text" do
    refute MentionRouter.addressed_anyone?("Team, quick status check please.", [])
    refute MentionRouter.addressed_anyone?("Status check, everyone.", [])
    refute MentionRouter.addressed_anyone?("Good morning team.", [])
  end
end
