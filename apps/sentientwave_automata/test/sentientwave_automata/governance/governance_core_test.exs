defmodule SentientwaveAutomata.GovernanceCoreTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Governance
  alias SentientwaveAutomata.Matrix.Directory

  test "opens all-member proposals with a human-only electorate and latest vote wins" do
    suffix = System.unique_integer([:positive])

    human = create_user(:person, "governance-human-#{suffix}")
    agent = create_user(:agent, "governance-agent-#{suffix}")
    service = create_user(:service, "governance-service-#{suffix}")

    assert {:ok, proposal} =
             Governance.open_law_proposal(%{
               "reference" => "LAW-#{suffix}",
               "proposal_type" => "create",
               "proposed_slug" => "human-rights-#{suffix}",
               "proposed_name" => "Human Rights #{suffix}",
               "proposed_markdown_body" => """
               # Human Rights

               Humans can initiate governance proposals.
               """,
               "created_by_id" => human.id,
               "room_id" => "!governance:localhost"
             })

    assert proposal.voting_scope == :all_members
    assert proposal.voting_rule_snapshot["approval_mode"] == "majority_of_cast"
    assert proposal.voting_rule_snapshot["quorum_percent"] == 50
    assert proposal.voting_rule_snapshot["voting_window_hours"] == 72

    assert Enum.map(proposal.electors, & &1.user_id) == [human.id]
    assert Governance.eligible_voter?(proposal, human.id)
    refute Governance.eligible_voter?(proposal, agent.id)
    refute Governance.eligible_voter?(proposal, service.id)

    assert {:error, :ineligible_voter} =
             Governance.cast_vote(proposal.id, agent.id, %{"choice" => "approve"})

    assert {:ok, first_vote} =
             Governance.cast_vote(proposal.id, human.id, %{"choice" => "approve"})

    assert first_vote.choice == :approve

    assert {:ok, second_vote} =
             Governance.cast_vote(proposal.id, human.id, %{"choice" => "reject"})

    assert second_vote.choice == :reject

    results = Governance.proposal_results(proposal.id)
    assert results.cast_count == 1
    assert results.reject_count == 1
    assert results.approval_met? == false
    assert results.quorum_met? == true

    assert {:ok, resolved} = Governance.resolve_proposal(proposal.id)
    assert resolved.status == :rejected
  end

  test "freezes role-based electorates and rejects unresolved proposals without votes" do
    suffix = System.unique_integer([:positive])

    human = create_user(:person, "governance-member-#{suffix}")
    agent = create_user(:agent, "governance-agent-member-#{suffix}")
    service = create_user(:service, "governance-service-member-#{suffix}")

    assert {:ok, role} =
             Governance.create_role(%{
               "slug" => "policy-council-#{suffix}",
               "name" => "Policy Council #{suffix}",
               "description" => "Role-scoped electorate",
               "enabled" => true
             })

    assert {:ok, _agent_assignment} = Governance.assign_role(role.id, agent.id, %{})
    assert {:ok, _service_assignment} = Governance.assign_role(role.id, service.id, %{})

    assert {:ok, proposal} =
             Governance.open_law_proposal(%{
               "reference" => "LAW-ROLE-#{suffix}",
               "proposal_type" => "create",
               "proposed_slug" => "role-policy-#{suffix}",
               "proposed_name" => "Role Policy #{suffix}",
               "proposed_markdown_body" => """
               # Role Policy

               Only members with a governance role may vote.
               """,
               "voting_scope" => "role_subset",
               "eligible_role_ids" => [role.id],
               "created_by_id" => human.id,
               "room_id" => "!governance:localhost"
             })

    assert Enum.sort(Enum.map(proposal.electors, & &1.user_id)) ==
             Enum.sort([agent.id, service.id])

    assert Governance.eligible_voter?(proposal.id, agent.id)
    assert Governance.eligible_voter?(proposal.id, service.id)
    refute Governance.eligible_voter?(proposal.id, human.id)

    assert proposal.voting_rule_snapshot["quorum_percent"] == 50

    assert {:ok, _later_policy} =
             Governance.create_law(%{
               "slug" => "voting-policy-#{suffix}",
               "name" => "Voting Policy #{suffix}",
               "markdown_body" => """
               # Voting Policy

               Governance rule changes are captured separately.
               """,
               "law_kind" => "voting_policy",
               "rule_config" => %{
                 "approval_mode" => "threshold_percent",
                 "approval_threshold_percent" => 75,
                 "quorum_percent" => 90,
                 "voting_window_hours" => 12
               }
             })

    assert proposal.voting_rule_snapshot["quorum_percent"] == 50

    assert {:ok, resolved} = Governance.resolve_proposal(proposal.id)
    assert resolved.status == :rejected
  end

  defp create_user(kind, localpart) do
    assert {:ok, user} =
             Directory.upsert_user(%{
               "localpart" => localpart,
               "kind" => kind,
               "display_name" => String.capitalize(to_string(kind)) <> " #{localpart}",
               "password" => "VerySecurePass123!"
             })

    user
  end
end
