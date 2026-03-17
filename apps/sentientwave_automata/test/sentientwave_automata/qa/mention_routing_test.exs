defmodule SentientwaveAutomata.QA.MentionRoutingTest do
  use ExUnit.Case, async: true

  @moduletag :qa_skeleton

  describe "mention routing" do
    @tag :skip
    test "routes message to exactly the mentioned agent(s)" do
      # Planned API shape (to implement):
      # mentions = SentientwaveAutomata.Matrix.Mentions.extract("hi @automata and @reviewer")
      # routes = SentientwaveAutomata.Agents.Router.route_mentions(mentions, room_id: "!r:hs")
      #
      # Key assertions:
      # assert Enum.sort(routes.agent_ids) == ["automata", "reviewer"]
      # assert Enum.uniq(routes.agent_ids) == routes.agent_ids
      # refute "planner" in routes.agent_ids
    end

    @tag :skip
    test "does not route when no agent mention is present" do
      # mentions = SentientwaveAutomata.Matrix.Mentions.extract("hello team")
      # routes = SentientwaveAutomata.Agents.Router.route_mentions(mentions, room_id: "!r:hs")
      #
      # Key assertions:
      # assert routes.agent_ids == []
      # assert routes.reason == :no_agent_mentioned
    end

    @tag :skip
    test "normalizes mention forms and preserves deterministic matching" do
      # mentions = SentientwaveAutomata.Matrix.Mentions.extract("@Automata, @automata:hs")
      # routes = SentientwaveAutomata.Agents.Router.route_mentions(mentions, room_id: "!r:hs")
      #
      # Key assertions:
      # assert routes.agent_ids == ["automata"]
      # assert routes.normalized_mentions == ["@automata"]
    end
  end
end
