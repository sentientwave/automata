defmodule SentientwaveAutomata.GovernanceTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Governance
  alias SentientwaveAutomata.Governance.Workflow
  alias SentientwaveAutomata.Matrix.Directory

  describe "governance roles and workflows" do
    test "opens proposals, snapshots electors, records votes, and publishes a constitution snapshot" do
      suffix = System.unique_integer([:positive])
      member_localpart = "governance-member-#{suffix}"

      assert {:ok, _member} =
               Directory.upsert_user(%{
                 localpart: member_localpart,
                 kind: :person,
                 display_name: "Governance Member",
                 password: "VerySecurePass123!"
               })

      member_record = Directory.get_user_record(member_localpart)
      assert member_record != nil

      assert {:ok, role} =
               Governance.create_role(%{
                 "slug" => "policy-council-#{suffix}",
                 "name" => "Policy Council",
                 "description" => "Approves constitution proposals",
                 "enabled" => true
               })

      assert {:ok, _assignment} = Governance.assign_role(role.id, member_record.id, %{})

      assert [%{id: ^role.id}] = Governance.list_user_roles(member_record.id)

      reference = "LAW-#{suffix}"
      proposal_room = "!governance:localhost"

      assert {:ok, proposal} =
               Workflow.open_proposal(%{
                 proposal_type: :create,
                 reference: reference,
                 proposed_slug: "member-rights-#{suffix}",
                 proposed_name: "Member Rights",
                 proposed_markdown_body: """
                 # Member Rights

                 Members may propose changes through Matrix governance commands.
                 """,
                 voting_scope: :role_subset,
                 eligible_role_ids: [role.id],
                 room_id: proposal_room,
                 sender_mxid: "@#{member_localpart}:localhost",
                 message_id: "$proposal-#{suffix}",
                 raw_event: %{"type" => "m.room.message"},
                 metadata: %{"source" => "test"}
               })

      assert proposal.reference == reference
      assert proposal.status == :open
      assert proposal.workflow_id != nil
      assert length(proposal.electors) == 1
      assert length(proposal.eligible_role_links) == 1

      assert {:ok, vote} =
               Workflow.cast_vote(%{
                 reference: reference,
                 choice: :approve,
                 room_id: proposal_room,
                 sender_mxid: "@#{member_localpart}:localhost",
                 message_id: "$vote-#{suffix}",
                 raw_event: %{"type" => "m.room.message"},
                 metadata: %{"source" => "test"}
               })

      assert vote.choice == :approve
      assert vote.room_id == proposal_room

      results = Workflow.proposal_results(reference)
      assert results.approve_count == 1
      assert results.quorum_met?
      assert results.approval_met?

      assert {:ok, resolved} = Workflow.resolve_proposal(reference)
      assert resolved.status == :approved

      snapshot = Workflow.current_constitution_snapshot()
      assert snapshot != nil
      assert snapshot.version >= 1
      assert Enum.any?(snapshot.laws, &(&1.slug == "member-rights-#{suffix}"))
    end
  end
end
