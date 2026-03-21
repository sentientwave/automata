defmodule SentientwaveAutomata.GovernanceSnapshotTest do
  use SentientwaveAutomata.DataCase, async: false

  alias SentientwaveAutomata.Governance
  alias SentientwaveAutomata.Matrix.Directory

  test "publishes constitution snapshots from ordered active laws" do
    suffix = System.unique_integer([:positive])
    publisher = create_user("governance-publisher-#{suffix}")

    assert {:ok, _later_law} =
             Governance.create_law(%{
               "slug" => "later-law-#{suffix}",
               "name" => "Later Law #{suffix}",
               "markdown_body" => """
               # Later Law

               This law comes second by position.
               """,
               "position" => 20
             })

    assert {:ok, _first_law} =
             Governance.create_law(%{
               "slug" => "first-law-#{suffix}",
               "name" => "First Law #{suffix}",
               "markdown_body" => """
               # First Law

               This law comes first by position.
               """,
               "position" => 10
             })

    assert {:ok, _repealed_law} =
             Governance.create_law(%{
               "slug" => "repealed-law-#{suffix}",
               "name" => "Repealed Law #{suffix}",
               "markdown_body" => """
               # Repealed Law

               This law should not appear in the active constitution.
               """,
               "position" => 30,
               "status" => "repealed"
             })

    assert {:ok, snapshot} =
             Governance.publish_constitution_snapshot(%{
               "published_by_id" => publisher.id,
               "note" => "manual snapshot"
             })

    assert snapshot.version == 1

    assert Enum.map(snapshot.law_memberships, & &1.law.slug) == [
             "first-law-#{suffix}",
             "later-law-#{suffix}"
           ]

    assert String.contains?(snapshot.prompt_text, "First Law #{suffix}")
    assert String.contains?(snapshot.prompt_text, "Later Law #{suffix}")
    refute String.contains?(snapshot.prompt_text, "Repealed Law #{suffix}")

    current = Governance.current_constitution_snapshot()
    assert current.id == snapshot.id
  end

  test "applies approved create amend and repeal proposals into new snapshots" do
    suffix = System.unique_integer([:positive])
    publisher = create_user("governance-voter-#{suffix}")

    assert {:ok, create_proposal} =
             Governance.open_law_proposal(%{
               "reference" => "LAW-CREATE-#{suffix}",
               "proposal_type" => "create",
               "proposed_slug" => "created-law-#{suffix}",
               "proposed_name" => "Created Law #{suffix}",
               "proposed_markdown_body" => """
               # Created Law

               Original law text.
               """,
               "created_by_id" => publisher.id
             })

    assert {:ok, create_vote} =
             Governance.cast_vote(create_proposal.id, publisher.id, %{"choice" => "approve"})

    assert create_vote.choice == :approve
    assert {:ok, approved_create} = Governance.resolve_proposal(create_proposal.id)
    assert approved_create.status == :approved

    assert {:ok, create_snapshot} = Governance.apply_approved_proposal(create_proposal.id)
    assert Enum.map(create_snapshot.law_memberships, & &1.law.slug) == ["created-law-#{suffix}"]

    created_law = Governance.get_law_by_slug("created-law-#{suffix}")
    assert created_law.status == :active

    assert {:ok, amend_proposal} =
             Governance.open_law_proposal(%{
               "reference" => "LAW-AMEND-#{suffix}",
               "proposal_type" => "amend",
               "law_id" => created_law.id,
               "proposed_markdown_body" => """
               # Created Law

               Revised law text.
               """,
               "created_by_id" => publisher.id
             })

    assert {:ok, _amend_vote} =
             Governance.cast_vote(amend_proposal.id, publisher.id, %{"choice" => "approve"})

    assert {:ok, approved_amend} = Governance.resolve_proposal(amend_proposal.id)
    assert approved_amend.status == :approved

    assert {:ok, amend_snapshot} = Governance.apply_approved_proposal(amend_proposal.id)
    amended_law = Governance.get_law(created_law.id)
    assert amended_law.version == created_law.version + 1
    assert String.contains?(amend_snapshot.prompt_text, "Revised law text.")

    assert {:ok, repeal_proposal} =
             Governance.open_law_proposal(%{
               "reference" => "LAW-REPEAL-#{suffix}",
               "proposal_type" => "repeal",
               "law_id" => created_law.id,
               "created_by_id" => publisher.id
             })

    assert {:ok, _repeal_vote} =
             Governance.cast_vote(repeal_proposal.id, publisher.id, %{"choice" => "approve"})

    assert {:ok, approved_repeal} = Governance.resolve_proposal(repeal_proposal.id)
    assert approved_repeal.status == :approved

    assert {:ok, repeal_snapshot} = Governance.apply_approved_proposal(repeal_proposal.id)
    repealed_law = Governance.get_law(created_law.id)
    assert repealed_law.status == :repealed
    refute Enum.any?(repeal_snapshot.law_memberships, &(&1.law.slug == "created-law-#{suffix}"))
  end

  defp create_user(localpart) do
    assert {:ok, user} =
             Directory.upsert_user(%{
               "localpart" => localpart,
               "kind" => "person",
               "display_name" => "Publisher #{localpart}",
               "password" => "VerySecurePass123!"
             })

    user
  end
end
