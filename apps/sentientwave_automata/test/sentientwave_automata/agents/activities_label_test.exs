defmodule SentientwaveAutomata.Agents.ActivitiesLabelTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Activities

  test "prefixes the response with the agent name and title" do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: "john.smith",
        kind: :agent,
        display_name: "John Smith",
        matrix_localpart: "john.smith",
        status: :active,
        metadata: %{"title" => "Risk & Insurance Advisor"}
      })

    text = Activities.label_agent_response(profile.id, "Umbrella renewal is on track.")

    assert text == "John Smith (Risk & Insurance Advisor): Umbrella renewal is on track."
  end

  test "uses just the name when there is no title" do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: "plain.agent",
        kind: :agent,
        display_name: "Plain Agent",
        matrix_localpart: "plain.agent",
        status: :active,
        metadata: %{}
      })

    assert Activities.label_agent_response(profile.id, "Hello.") == "Plain Agent: Hello."
  end

  test "leaves the text untouched without an agent" do
    assert Activities.label_agent_response(nil, "Hello.") == "Hello."
    assert Activities.label_agent_response(Ecto.UUID.generate(), "Hello.") == "Hello."
  end
end
