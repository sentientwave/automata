defmodule SentientwaveAutomata.GovernanceMatrixTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Governance.Workflow
  alias SentientwaveAutomata.Matrix.Directory

  describe "matrix governance command handling" do
    test "accepts proposal and vote commands from the governance room and ignores other rooms" do
      suffix = System.unique_integer([:positive])
      localpart = "governance-voter-#{suffix}"
      reference = "LAW-ROOM-#{suffix}"
      governance_room = "!governance:localhost"

      assert {:ok, _user} =
               Directory.upsert_user(%{
                 localpart: localpart,
                 kind: :person,
                 display_name: "Governance Voter",
                 password: "VerySecurePass123!"
               })

      proposal_event = %{
        "type" => "m.room.message",
        "room_id" => governance_room,
        "sender" => "@#{localpart}:localhost",
        "event_id" => "$proposal-#{suffix}",
        "content" => %{
          "body" =>
            "proposal create " <>
              Jason.encode!(%{
                "reference" => reference,
                "proposed_slug" => "room-policy-#{suffix}",
                "proposed_name" => "Room Policy",
                "proposed_markdown_body" => """
                # Room Policy

                Governance proposals are managed in the governance room.
                """,
                "voting_scope" => "all_members"
              })
        }
      }

      assert :ok = SentientwaveAutomata.Adapters.Matrix.Local.ingest_event(proposal_event)

      results = Workflow.proposal_results(reference)
      assert results.cast_count == 0
      assert results.eligible_count >= 1

      vote_event = %{
        "type" => "m.room.message",
        "room_id" => governance_room,
        "sender" => "@#{localpart}:localhost",
        "event_id" => "$vote-#{suffix}",
        "content" => %{"body" => "vote #{reference} approve"}
      }

      assert :ok = SentientwaveAutomata.Adapters.Matrix.Local.ingest_event(vote_event)

      updated = Workflow.proposal_results(reference)
      assert updated.approve_count == 1
      assert updated.cast_count == 1

      ignored_event = %{
        "type" => "m.room.message",
        "room_id" => "!random:localhost",
        "sender" => "@#{localpart}:localhost",
        "event_id" => "$vote-ignore-#{suffix}",
        "content" => %{"body" => "vote #{reference} reject"}
      }

      assert :ok = SentientwaveAutomata.Adapters.Matrix.Local.ingest_event(ignored_event)

      refetched = Workflow.proposal_results(reference)
      assert refetched.approve_count == 1
      assert refetched.reject_count == 0
    end
  end
end
