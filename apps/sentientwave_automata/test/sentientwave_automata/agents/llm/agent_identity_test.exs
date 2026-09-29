defmodule SentientwaveAutomata.Agents.LLM.AgentIdentityTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.LLM.Client

  test "falls back to slug when no agent profile exists" do
    text = Client.agent_identity_text("some.agent", nil)

    assert text =~ "You are some.agent"
    assert text =~ "collaborative automation agent in Matrix"
  end

  test "uses the agent profile persona (name, title, bio) when present" do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: "mary.jones",
        kind: :agent,
        display_name: "Mary Jones",
        matrix_localpart: "mary.jones",
        status: :active,
        metadata: %{
          "title" => "Chief Investment Officer, Public Markets",
          "department" => "Investments Department",
          "team" => "Public Markets Team",
          "bio" => "Mary spent 18 years at a global asset manager.",
          "focus" => "Global equities · asset allocation"
        }
      })

    text = Client.agent_identity_text("mary.jones", profile.id)

    assert text =~ "You are Mary Jones"
    assert text =~ "@mary.jones"
    assert text =~ "Your role: Chief Investment Officer, Public Markets"
    assert text =~ "Your department: Investments Department"
    assert text =~ "Your team: Public Markets Team"
    assert text =~ "Your background: Mary spent 18 years"
    assert text =~ "Your focus areas: Global equities"
  end

  test "omits the org line when no org name is configured" do
    previous = System.get_env("AUTOMATA_ORG_NAME")
    System.delete_env("AUTOMATA_ORG_NAME")

    on_exit(fn ->
      if previous, do: System.put_env("AUTOMATA_ORG_NAME", previous)
    end)

    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: "plain.agent",
        kind: :agent,
        display_name: "Plain Agent",
        matrix_localpart: "plain.agent",
        status: :active,
        metadata: %{}
      })

    text = Client.agent_identity_text("plain.agent", profile.id)
    refute text =~ "of the"
  end

  test "includes a configured org name in the identity" do
    previous = System.get_env("AUTOMATA_ORG_NAME")
    System.put_env("AUTOMATA_ORG_NAME", "Example Org")

    on_exit(fn ->
      if previous,
        do: System.put_env("AUTOMATA_ORG_NAME", previous),
        else: System.delete_env("AUTOMATA_ORG_NAME")
    end)

    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: "plain.agent",
        kind: :agent,
        display_name: "Plain Agent",
        matrix_localpart: "plain.agent",
        status: :active,
        metadata: %{}
      })

    text = Client.agent_identity_text("plain.agent", profile.id)
    assert text =~ "of Example Org"
  end

  test "omits empty persona fields" do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: "plain.agent",
        kind: :agent,
        display_name: "Plain Agent",
        matrix_localpart: "plain.agent",
        status: :active,
        metadata: %{}
      })

    text = Client.agent_identity_text("plain.agent", profile.id)

    assert text =~ "You are Plain Agent"
    refute text =~ "Your role:"
    refute text =~ "Your background:"
  end
end
