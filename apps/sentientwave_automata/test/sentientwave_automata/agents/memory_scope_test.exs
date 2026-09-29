defmodule SentientwaveAutomata.Agents.MemoryScopeTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.MemoryStore

  setup do
    {:ok, agent} =
      Agents.upsert_agent(%{
        slug: "scoped.agent",
        kind: :agent,
        display_name: "Scoped Agent",
        matrix_localpart: "scoped.agent",
        status: :active,
        metadata: %{}
      })

    {:ok, room_a} =
      Agents.create_memory(%{
        agent_id: agent.id,
        source: "test",
        content: "umbrella renewal progress in room A",
        embedding: [1.0, 0.0, 0.0],
        metadata: %{"room_id" => "!roomA", "scope" => "room"}
      })

    {:ok, room_b} =
      Agents.create_memory(%{
        agent_id: agent.id,
        source: "test",
        content: "kitchen renovation notes in room B",
        embedding: [0.0, 1.0, 0.0],
        metadata: %{"room_id" => "!roomB", "scope" => "room"}
      })

    {:ok, personal} =
      Agents.create_memory(%{
        agent_id: agent.id,
        source: "test",
        content: "I promised the boss a weekly risk digest",
        embedding: [0.0, 0.0, 1.0],
        metadata: %{"scope" => "personal"}
      })

    {:ok, legacy} =
      Agents.create_memory(%{
        agent_id: agent.id,
        source: "test",
        content: "legacy untagged memory",
        embedding: [1.0, 1.0, 0.0],
        metadata: %{}
      })

    %{agent: agent, room_a: room_a, room_b: room_b, personal: personal, legacy: legacy}
  end

  test "search_room returns only the agent's memories for that room", %{
    agent: agent,
    room_a: room_a
  } do
    {:ok, rows} = MemoryStore.search_room(agent.id, "!roomA", "umbrella renewal", top_k: 10)

    ids = Enum.map(rows, & &1.id)
    assert room_a.id in ids
    refute Enum.any?(rows, &(&1.id != room_a.id))
  end

  test "search_personal returns personal and legacy untagged memories", %{
    agent: agent,
    personal: personal,
    legacy: legacy
  } do
    {:ok, rows} = MemoryStore.search_personal(agent.id, "promised digest", top_k: 10)

    ids = Enum.map(rows, & &1.id)
    assert personal.id in ids
    assert legacy.id in ids
  end

  test "search without scope returns everything for the agent", %{
    agent: agent,
    room_b: room_b
  } do
    {:ok, rows} = MemoryStore.search(agent.id, "renovation", top_k: 10)

    assert Enum.any?(rows, &(&1.id == room_b.id))
    assert length(rows) == 4
  end
end

defmodule SentientwaveAutomata.Agents.MemoryDedupeTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.MemoryStore

  test "personal_memory_exists? detects identical personal entries" do
    {:ok, agent} =
      Agents.upsert_agent(%{
        slug: "dedupe.agent",
        kind: :agent,
        display_name: "Dedupe Agent",
        matrix_localpart: "dedupe.agent",
        status: :active,
        metadata: %{}
      })

    refute MemoryStore.personal_memory_exists?(agent.id, "I promised to send a weekly digest")

    {:ok, _mem} =
      MemoryStore.ingest(agent.id, "I promised to send a weekly digest",
        source: "test",
        metadata: %{"scope" => "personal"}
      )

    assert MemoryStore.personal_memory_exists?(agent.id, "I promised to send a weekly digest")

    # room-scoped entries are not personal
    {:ok, _room} =
      MemoryStore.ingest(agent.id, "room-only note",
        source: "test",
        metadata: %{"scope" => "room", "room_id" => "!room:localhost"}
      )

    refute MemoryStore.personal_memory_exists?(agent.id, "room-only note")
  end
end
