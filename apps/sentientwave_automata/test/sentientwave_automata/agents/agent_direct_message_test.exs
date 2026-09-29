defmodule SentientwaveAutomata.Agents.AgentDirectMessageTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
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

    _ =
      Directory.upsert_user(
        %{
          localpart: "john.smith",
          kind: :agent,
          display_name: "John Smith",
          password: "password-12345",
          admin: false,
          metadata: %{"title" => "Head of Risk & Insurance"}
        },
        seed: true
      )

    _ =
      Directory.upsert_user(
        %{
          localpart: "jane.doe",
          kind: :agent,
          display_name: "Jane Doe",
          password: "password-12345",
          admin: false,
          metadata: %{"title" => "Personal Cybersecurity Risk Analyst"}
        },
        seed: true
      )

    %{}
  end

  test "agent-sent message triggers only the mentioned colleague", %{} do
    assert {:ok, %{target_count: 1, run_ids: [run_id]}} =
             MentionDispatcher.dispatch(%{
               room_id: "!dm:localhost",
               sender_mxid: "@john.smith:localhost",
               message_id: "msg-#{System.unique_integer([:positive])}",
               body: "@jane.doe please review the report"
             })

    run = Agents.get_run(run_id)
    agent = Agents.get_agent(run.agent_id)
    assert agent.slug == "jane.doe"
    assert run.metadata["sender_is_agent"] == true
    assert run.metadata["explicitly_mentioned"] == true
  end

  test "a two-agent P2P room triggers the opposite agent without an @mention" do
    members = ["@john.smith:localhost", "@jane.doe:localhost"]

    targets =
      MentionRouter.resolve_targets(
        "The memo is on track.",
        room_id: "!p2p:localhost",
        sender_mxid: "@john.smith:localhost",
        explicit_only: true,
        joined_members: members
      )

    assert [%{slug: "jane.doe"}] = targets
  end

  test "a human message also wakes the agent in a two-agent P2P room" do
    members = ["@boss:localhost", "@jane.doe:localhost"]

    targets =
      MentionRouter.resolve_targets(
        "Hello, are you there?",
        room_id: "!p2p-human:localhost",
        sender_mxid: "@boss:localhost",
        joined_members: members
      )

    assert [%{slug: "jane.doe"}] = targets
  end

  test "an unaddressed agent message in a public room does not fan out" do
    members = [
      "@john.smith:localhost",
      "@jane.doe:localhost",
      "@boss:localhost"
    ]

    targets =
      MentionRouter.resolve_targets(
        "The memo is on track.",
        room_id: "!public:localhost",
        sender_mxid: "@john.smith:localhost",
        explicit_only: true,
        joined_members: members
      )

    assert targets == []
  end

  test "a public room still requires an explicit destination for agent-sent messages" do
    members = [
      "@john.smith:localhost",
      "@jane.doe:localhost",
      "@boss:localhost"
    ]

    targets =
      MentionRouter.resolve_targets(
        "@jane.doe please review the report",
        room_id: "!public:localhost",
        sender_mxid: "@john.smith:localhost",
        joined_members: members
      )

    assert [%{slug: "jane.doe"}] = targets
  end

  test "agent-sent message without a mention starts no runs", %{} do
    assert {:error, :agent_message_no_mentioned_targets} =
             MentionDispatcher.dispatch(%{
               room_id: "!dm:localhost",
               sender_mxid: "@john.smith:localhost",
               message_id: "msg-#{System.unique_integer([:positive])}",
               body: "The memo is on track."
             })
  end

  test "agent-sent message mentioning a person only starts no runs", %{} do
    assert {:error, :agent_message_no_mentioned_targets} =
             MentionDispatcher.dispatch(%{
               room_id: "!dm:localhost",
               sender_mxid: "@john.smith:localhost",
               message_id: "msg-#{System.unique_integer([:positive])}",
               body: "@boss heads-up: memo is ready"
             })
  end
end

defmodule SentientwaveAutomata.Agents.AgentConversationBudgetTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.MentionDispatcher
  alias SentientwaveAutomata.Agents.Mention
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Repo

  setup do
    previous_autonomy = System.get_env("AUTOMATA_ROOM_AUTONOMY_ENABLED")
    previous_max = System.get_env("AUTOMATA_AGENT_AGENT_MAX_ROUNDS_PER_WINDOW")
    System.put_env("AUTOMATA_ROOM_AUTONOMY_ENABLED", "true")
    System.put_env("AUTOMATA_AGENT_AGENT_MAX_ROUNDS_PER_WINDOW", "2")

    on_exit(fn ->
      restore = fn name, value ->
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      restore.("AUTOMATA_ROOM_AUTONOMY_ENABLED", previous_autonomy)
      restore.("AUTOMATA_AGENT_AGENT_MAX_ROUNDS_PER_WINDOW", previous_max)
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

  test "caps agent-to-agent rounds per room within the window" do
    room = "!budget-room:localhost"

    for n <- 1..2 do
      assert {:ok, %{target_count: 1}} =
               MentionDispatcher.dispatch(%{
                 room_id: room,
                 sender_mxid: "@john.smith:localhost",
                 message_id: "msg-#{n}-#{System.unique_integer([:positive])}",
                 body: "@jane.doe question number #{n}"
               })
    end

    # the third agent-sent message in the window is blocked
    assert {:error, :agent_conversation_cooldown} =
             MentionDispatcher.dispatch(%{
               room_id: room,
               sender_mxid: "@john.smith:localhost",
               message_id: "msg-3-#{System.unique_integer([:positive])}",
               body: "@jane.doe question number 3"
             })

    # person-sent messages are never blocked by the agent budget
    person_result =
      MentionDispatcher.dispatch(%{
        room_id: room,
        sender_mxid: "@boss:localhost",
        message_id: "msg-person-#{System.unique_integer([:positive])}",
        body: "status update everyone"
      })

    refute match?({:error, :agent_conversation_cooldown}, person_result)
  end

  test "tags agent-sent mentions with sender_is_agent" do
    assert {:ok, %{mention_id: mention_id}} =
             MentionDispatcher.dispatch(%{
               room_id: "!tag-room:localhost",
               sender_mxid: "@john.smith:localhost",
               message_id: "msg-tag-#{System.unique_integer([:positive])}",
               body: "@jane.doe please confirm"
             })

    mention = Repo.get!(Mention, mention_id)
    assert mention.metadata["sender_is_agent"] == true
  end
end

defmodule SentientwaveAutomata.Agents.DuplicateDispatchTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.MentionDispatcher
  alias SentientwaveAutomata.Agents.Run
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Repo

  import Ecto.Query, warn: false

  setup do
    previous = System.get_env("AUTOMATA_ROOM_AUTONOMY_ENABLED")
    System.put_env("AUTOMATA_ROOM_AUTONOMY_ENABLED", "true")

    on_exit(fn ->
      if previous,
        do: System.put_env("AUTOMATA_ROOM_AUTONOMY_ENABLED", previous),
        else: System.delete_env("AUTOMATA_ROOM_AUTONOMY_ENABLED")
    end)

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

    %{}
  end

  test "a replayed message never starts duplicate runs" do
    attrs = %{
      room_id: "!replay:localhost",
      sender_mxid: "@nadia.anderson:localhost",
      message_id: "replay-msg-#{System.unique_integer([:positive])}",
      body: "@jane.doe please confirm"
    }

    assert {:ok, %{run_ids: [first_run]}} = MentionDispatcher.dispatch(attrs)

    # same message arriving again (timeline replay) must be skipped
    assert {:error, :already_processed} = MentionDispatcher.dispatch(attrs)

    runs =
      Repo.all(
        from r in Run,
          where:
            r.mention_id in subquery(
              from m in SentientwaveAutomata.Agents.Mention,
                where: m.message_id == ^attrs.message_id,
                select: m.id
            )
      )

    assert [run_id] = Enum.map(runs, & &1.id)
    assert run_id == first_run
  end
end
