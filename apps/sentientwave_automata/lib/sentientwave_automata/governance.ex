defmodule SentientwaveAutomata.Governance do
  @moduledoc """
  Company constitution, governance roles, proposals, votes, and published
  constitution snapshots.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Governance.{
    ConstitutionSnapshot,
    ConstitutionSnapshotLaw,
    Law,
    LawProposal,
    LawVote,
    ProposalElector,
    ProposalEligibleRole,
    Role,
    RoleAssignment
  }

  alias SentientwaveAutomata.Matrix.DirectoryUser
  alias SentientwaveAutomata.Repo

  @default_voting_rule_config %{
    "approval_mode" => "majority_cast",
    "approval_threshold_percent" => 50,
    "quorum_percent" => 50,
    "voting_window_hours" => 72
  }

  @spec default_voting_rule_config() :: map()
  def default_voting_rule_config, do: @default_voting_rule_config

  @spec list_laws(keyword()) :: [Law.t()]
  def list_laws(opts \\ []) do
    Law
    |> maybe_filter_law_status(opts)
    |> maybe_filter_law_kind(opts)
    |> maybe_search_laws(option_get(opts, :q))
    |> order_by([law], asc: law.position, asc: law.slug, asc: law.version)
    |> Repo.all()
  end

  @spec count_laws(keyword()) :: non_neg_integer()
  def count_laws(opts \\ []) do
    Law
    |> maybe_filter_law_status(opts)
    |> maybe_filter_law_kind(opts)
    |> maybe_search_laws(option_get(opts, :q))
    |> Repo.aggregate(:count, :id)
  end

  @spec get_law(binary() | Law.t()) :: Law.t() | nil
  def get_law(%Law{} = law), do: preload_law(law)

  def get_law(id) when is_binary(id) do
    case Repo.get(Law, id) do
      nil -> nil
      law -> preload_law(law)
    end
  end

  @spec get_law!(binary()) :: Law.t()
  def get_law!(id) when is_binary(id), do: id |> Repo.get!(Law) |> preload_law()

  @spec get_law_by_slug(String.t()) :: Law.t() | nil
  def get_law_by_slug(slug) when is_binary(slug) do
    slug
    |> normalize_slug()
    |> case do
      "" -> nil
      normalized -> Repo.get_by(Law, slug: normalized)
    end
    |> case do
      nil -> nil
      law -> preload_law(law)
    end
  end

  @spec create_law(map()) :: {:ok, Law.t()} | {:error, Ecto.Changeset.t()}
  def create_law(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> normalize_map()
      |> Map.put_new("status", "active")
      |> Map.put_new("position", next_law_position())
      |> Map.put_new("version", 1)
      |> maybe_put_law_timestamps()

    %Law{}
    |> Law.changeset(attrs)
    |> Repo.insert()
  end

  @spec update_law(Law.t(), map()) :: {:ok, Law.t()} | {:error, Ecto.Changeset.t()}
  def update_law(%Law{} = law, attrs) when is_map(attrs) do
    law
    |> Law.changeset(attrs |> normalize_map() |> maybe_put_law_timestamps())
    |> Repo.update()
  end

  @spec list_active_laws_for_prompt() :: [Law.t()]
  def list_active_laws_for_prompt do
    Law
    |> where([law], law.status == :active)
    |> order_by([law], asc: law.position, asc: law.slug, asc: law.version)
    |> Repo.all()
  end

  @spec list_roles(keyword()) :: [Role.t()]
  def list_roles(opts \\ []) do
    Role
    |> maybe_filter_role_enabled(opts)
    |> maybe_search_roles(option_get(opts, :q))
    |> order_by([role], asc: role.name, asc: role.slug)
    |> Repo.all()
  end

  @spec count_roles(keyword()) :: non_neg_integer()
  def count_roles(opts \\ []) do
    Role
    |> maybe_filter_role_enabled(opts)
    |> maybe_search_roles(option_get(opts, :q))
    |> Repo.aggregate(:count, :id)
  end

  @spec get_role(binary() | Role.t()) :: Role.t() | nil
  def get_role(%Role{} = role), do: preload_role(role)

  def get_role(id) when is_binary(id) do
    case Repo.get(Role, id) do
      nil -> nil
      role -> preload_role(role)
    end
  end

  @spec get_role_by_slug(String.t()) :: Role.t() | nil
  def get_role_by_slug(slug) when is_binary(slug) do
    slug
    |> normalize_slug()
    |> case do
      "" -> nil
      normalized -> Repo.get_by(Role, slug: normalized)
    end
    |> case do
      nil -> nil
      role -> preload_role(role)
    end
  end

  @spec create_role(map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def create_role(attrs) when is_map(attrs) do
    %Role{}
    |> Role.changeset(normalize_map(attrs))
    |> Repo.insert()
  end

  @spec update_role(Role.t(), map()) :: {:ok, Role.t()} | {:error, Ecto.Changeset.t()}
  def update_role(%Role{} = role, attrs) when is_map(attrs) do
    role
    |> Role.changeset(normalize_map(attrs))
    |> Repo.update()
  end

  @spec list_user_roles(binary()) :: [Role.t()]
  def list_user_roles(user_id) when is_binary(user_id) do
    Role
    |> join(:inner, [role], assignment in RoleAssignment, on: assignment.role_id == role.id)
    |> where([role, assignment], assignment.user_id == ^user_id and assignment.status == :active)
    |> where([role, _assignment], role.enabled == true)
    |> order_by([role, _assignment], asc: role.name, asc: role.slug)
    |> Repo.all()
  end

  @spec list_role_assignments(binary(), keyword()) :: [RoleAssignment.t()]
  def list_role_assignments(role_id, opts \\ []) when is_binary(role_id) do
    RoleAssignment
    |> where([assignment], assignment.role_id == ^role_id)
    |> maybe_filter_assignment_status(opts)
    |> order_by([assignment], desc: assignment.assigned_at, desc: assignment.inserted_at)
    |> preload([:role, :user])
    |> Repo.all()
  end

  @spec assign_role(binary(), binary(), map()) :: {:ok, RoleAssignment.t()} | {:error, term()}
  def assign_role(role_id, user_id, attrs)
      when is_binary(role_id) and is_binary(user_id) and is_map(attrs) do
    case Repo.get_by(RoleAssignment, role_id: role_id, user_id: user_id, status: :active) do
      %RoleAssignment{} = assignment ->
        {:ok, Repo.preload(assignment, [:role, :user])}

      nil ->
        %RoleAssignment{}
        |> RoleAssignment.changeset(
          attrs
          |> normalize_map()
          |> Map.put("role_id", role_id)
          |> Map.put("user_id", user_id)
          |> Map.put_new("status", "active")
          |> Map.put_new("assigned_at", DateTime.utc_now())
        )
        |> Repo.insert()
        |> case do
          {:ok, assignment} -> {:ok, Repo.preload(assignment, [:role, :user])}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec assign_role(binary(), map()) :: {:ok, RoleAssignment.t()} | {:error, term()}
  def assign_role(role_id, attrs) when is_binary(role_id) and is_map(attrs) do
    user_id = Map.get(attrs, "user_id") || Map.get(attrs, :user_id)

    if is_binary(user_id) and String.trim(user_id) != "" do
      assign_role(role_id, String.trim(user_id), Map.delete(normalize_map(attrs), "user_id"))
    else
      {:error, :user_id_required}
    end
  end

  @spec revoke_role_assignment(binary(), map()) :: {:ok, RoleAssignment.t()} | {:error, term()}
  def revoke_role_assignment(assignment_id, attrs)
      when is_binary(assignment_id) and is_map(attrs) do
    case Repo.get(RoleAssignment, assignment_id) do
      nil ->
        {:error, :not_found}

      %RoleAssignment{status: :revoked} = assignment ->
        {:ok, Repo.preload(assignment, [:role, :user])}

      %RoleAssignment{} = assignment ->
        assignment
        |> RoleAssignment.changeset(
          attrs
          |> normalize_map()
          |> Map.put("status", "revoked")
          |> Map.put_new("revoked_at", DateTime.utc_now())
        )
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, Repo.preload(updated, [:role, :user])}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec revoke_role_assignment(binary(), binary()) :: {:ok, RoleAssignment.t()} | {:error, term()}
  def revoke_role_assignment(role_id, assignment_id)
      when is_binary(role_id) and is_binary(assignment_id) do
    case Repo.get(RoleAssignment, assignment_id) do
      %RoleAssignment{role_id: ^role_id} -> revoke_role_assignment(assignment_id, %{})
      %RoleAssignment{} -> {:error, :not_found}
      nil -> {:error, :not_found}
    end
  end

  @spec list_proposals(keyword()) :: [LawProposal.t()]
  def list_proposals(opts \\ []) do
    LawProposal
    |> maybe_filter_proposal_status(opts)
    |> maybe_filter_proposal_type(opts)
    |> maybe_search_proposals(option_get(opts, :q))
    |> maybe_filter_proposal_room(option_get(opts, :room_id))
    |> order_by([proposal], desc: proposal.opened_at, desc: proposal.inserted_at)
    |> Repo.all()
    |> Repo.preload(proposal_preloads())
  end

  @spec count_proposals(keyword()) :: non_neg_integer()
  def count_proposals(opts \\ []) do
    LawProposal
    |> maybe_filter_proposal_status(opts)
    |> maybe_filter_proposal_type(opts)
    |> maybe_search_proposals(option_get(opts, :q))
    |> maybe_filter_proposal_room(option_get(opts, :room_id))
    |> Repo.aggregate(:count, :id)
  end

  @spec get_proposal(binary() | LawProposal.t()) :: LawProposal.t() | nil
  def get_proposal(%LawProposal{} = proposal), do: Repo.preload(proposal, proposal_preloads())

  def get_proposal(id) when is_binary(id) do
    case Repo.get(LawProposal, id) do
      nil -> nil
      proposal -> Repo.preload(proposal, proposal_preloads())
    end
  end

  @spec get_proposal!(binary()) :: LawProposal.t()
  def get_proposal!(id) when is_binary(id),
    do: id |> Repo.get!(LawProposal) |> Repo.preload(proposal_preloads())

  @spec get_proposal_by_reference(String.t()) :: LawProposal.t() | nil
  def get_proposal_by_reference(reference) when is_binary(reference) do
    reference = String.trim(reference)

    case Repo.get_by(LawProposal, reference: reference) do
      nil -> nil
      proposal -> Repo.preload(proposal, proposal_preloads())
    end
  end

  @spec list_proposal_electors(binary()) :: [ProposalElector.t()]
  def list_proposal_electors(proposal_id) when is_binary(proposal_id) do
    ProposalElector
    |> where([elector], elector.proposal_id == ^proposal_id)
    |> order_by([elector], asc: elector.inserted_at)
    |> preload([:user])
    |> Repo.all()
  end

  @spec list_proposal_eligible_roles(binary()) :: [ProposalEligibleRole.t()]
  def list_proposal_eligible_roles(proposal_id) when is_binary(proposal_id) do
    ProposalEligibleRole
    |> where([link], link.proposal_id == ^proposal_id)
    |> order_by([link], asc: link.inserted_at)
    |> preload([:role])
    |> Repo.all()
  end

  @spec open_law_proposal(map()) :: {:ok, LawProposal.t()} | {:error, term()}
  def open_law_proposal(attrs) when is_map(attrs) do
    attrs = normalize_map(attrs)
    now = DateTime.utc_now()

    voting_rule_snapshot =
      Map.merge(resolve_voting_rule_snapshot(), normalize_rule_snapshot(attrs))

    voting_scope = voting_scope(attrs)
    role_ids = proposal_role_ids(attrs)

    proposal_attrs =
      attrs
      |> Map.put_new("reference", generate_reference("LAW"))
      |> Map.put_new("proposal_type", "create")
      |> Map.put_new("status", "open")
      |> Map.put_new("voting_scope", Atom.to_string(voting_scope))
      |> Map.put("law_id", resolve_law_identifier(Map.get(attrs, "law_id")))
      |> Map.put("proposed_slug", resolve_proposed_slug(attrs))
      |> Map.put("proposed_name", resolve_proposed_name(attrs))
      |> Map.put("proposed_markdown_body", blank_to_nil(Map.get(attrs, "proposed_markdown_body")))
      |> Map.put(
        "proposed_law_kind",
        Atom.to_string(
          normalize_enum(Map.get(attrs, "proposed_law_kind"), Law.law_kinds(), :general)
        )
      )
      |> Map.put(
        "proposed_rule_config",
        normalize_map(Map.get(attrs, "rule_config", Map.get(attrs, "proposed_rule_config", %{})))
      )
      |> Map.put("reason", blank_to_nil(Map.get(attrs, "reason")))
      |> Map.put("voting_rule_snapshot", voting_rule_snapshot)
      |> Map.put_new("opened_at", now)
      |> Map.put_new(
        "closes_at",
        DateTime.add(now, voting_window_hours(voting_rule_snapshot), :hour)
      )
      |> Map.put_new("room_id", blank_to_nil(Map.get(attrs, "room_id")))
      |> Map.put_new("proposal_message_id", blank_to_nil(Map.get(attrs, "proposal_message_id")))
      |> Map.put_new("raw_event", normalize_map(Map.get(attrs, "raw_event", %{})))
      |> Map.put_new("metadata", normalize_map(Map.get(attrs, "metadata", %{})))

    cond do
      blank?(Map.get(proposal_attrs, "created_by_id")) ->
        {:error, :created_by_required}

      proposal_type(proposal_attrs) in [:amend, :repeal] and
          blank?(Map.get(proposal_attrs, "law_id")) ->
        {:error, :law_required}

      voting_scope == :role_subset and role_ids == [] ->
        {:error, :eligible_roles_required}

      true ->
        Repo.transaction(fn ->
          with {:ok, proposal} <- insert_proposal(proposal_attrs),
               :ok <- snapshot_proposal_electorate(proposal, role_ids) do
            Repo.preload(proposal, proposal_preloads())
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  @spec cast_vote(binary(), binary(), map()) :: {:ok, LawVote.t()} | {:error, term()}
  def cast_vote(proposal_id, voter_id, attrs)
      when is_binary(proposal_id) and is_binary(voter_id) and is_map(attrs) do
    attrs = normalize_map(attrs)

    with %LawProposal{} = proposal <- get_proposal(proposal_id),
         true <- proposal.status == :open || {:error, :not_open},
         true <- eligible_voter?(proposal.id, voter_id) || {:error, :ineligible_voter} do
      vote_attrs =
        attrs
        |> Map.put("proposal_id", proposal_id)
        |> Map.put("voter_id", voter_id)
        |> Map.put(
          "choice",
          Atom.to_string(normalize_enum(Map.get(attrs, "choice"), LawVote.choices(), :reject))
        )
        |> Map.put_new("cast_at", DateTime.utc_now())
        |> Map.put_new("raw_event", normalize_map(Map.get(attrs, "raw_event", %{})))
        |> Map.put_new("metadata", normalize_map(Map.get(attrs, "metadata", %{})))

      case Repo.get_by(LawVote, proposal_id: proposal_id, voter_id: voter_id) do
        %LawVote{} = vote ->
          vote
          |> LawVote.changeset(vote_attrs)
          |> Repo.update()
          |> preload_vote_result()

        nil ->
          %LawVote{}
          |> LawVote.changeset(vote_attrs)
          |> Repo.insert()
          |> preload_vote_result()
      end
    else
      false -> {:error, :not_open}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
    end
  end

  @spec eligible_voter?(binary() | LawProposal.t(), binary()) :: boolean()
  def eligible_voter?(%LawProposal{} = proposal, voter_id) when is_binary(voter_id),
    do: eligible_voter?(proposal.id, voter_id)

  def eligible_voter?(proposal_id, voter_id)
      when is_binary(proposal_id) and is_binary(voter_id) do
    ProposalElector
    |> where([elector], elector.proposal_id == ^proposal_id and elector.user_id == ^voter_id)
    |> Repo.exists?()
  end

  @spec proposal_results(binary() | LawProposal.t()) :: map()
  def proposal_results(%LawProposal{} = proposal), do: proposal_results(proposal.id)

  def proposal_results(proposal_id) when is_binary(proposal_id) do
    case get_proposal(proposal_id) do
      nil -> empty_results()
      proposal -> summarize_results(compute_proposal_results(proposal))
    end
  end

  @spec resolve_proposal(binary() | LawProposal.t()) :: {:ok, LawProposal.t()} | {:error, term()}
  def resolve_proposal(%LawProposal{} = proposal), do: resolve_proposal(proposal.id)

  def resolve_proposal(proposal_id) when is_binary(proposal_id) do
    case get_proposal(proposal_id) do
      nil ->
        {:error, :not_found}

      %LawProposal{status: status} = proposal when status in [:approved, :rejected, :cancelled] ->
        {:ok, proposal}

      %LawProposal{} = proposal ->
        results = compute_proposal_results(proposal)
        resolved_status = resolved_proposal_status(results)

        proposal
        |> LawProposal.changeset(%{
          "status" => Atom.to_string(resolved_status),
          "resolved_at" => DateTime.utc_now()
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, Repo.preload(updated, proposal_preloads())}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec apply_approved_proposal(binary() | LawProposal.t()) ::
          {:ok, ConstitutionSnapshot.t()} | {:error, term()}
  def apply_approved_proposal(%LawProposal{} = proposal), do: apply_approved_proposal(proposal.id)

  def apply_approved_proposal(proposal_id) when is_binary(proposal_id) do
    case get_constitution_snapshot_by_proposal_id(proposal_id) do
      %ConstitutionSnapshot{} = snapshot ->
        {:ok, snapshot}

      nil ->
        Repo.transaction(fn ->
          proposal =
            case get_proposal(proposal_id) do
              nil -> Repo.rollback(:not_found)
              proposal -> proposal
            end

          proposal =
            case proposal.status do
              :approved ->
                proposal

              :open ->
                case resolve_proposal(proposal) do
                  {:ok, resolved} -> resolved
                  {:error, reason} -> Repo.rollback(reason)
                end

              _ ->
                Repo.rollback(:not_approved)
            end

          if proposal.status != :approved, do: Repo.rollback(:not_approved)

          with {:ok, _law} <- apply_proposal_to_law(proposal),
               {:ok, snapshot} <- publish_snapshot_for_laws(proposal) do
            snapshot
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  @spec list_constitution_snapshots(keyword()) :: [ConstitutionSnapshot.t()]
  def list_constitution_snapshots(opts \\ []) do
    ConstitutionSnapshot
    |> maybe_filter_snapshot_proposal(opts)
    |> order_by([snapshot], desc: snapshot.version, desc: snapshot.published_at)
    |> Repo.all()
    |> Enum.map(&preload_snapshot/1)
  end

  @spec current_constitution_snapshot() :: ConstitutionSnapshot.t() | nil
  def current_constitution_snapshot do
    ConstitutionSnapshot
    |> order_by([snapshot], desc: snapshot.version, desc: snapshot.published_at)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      snapshot -> preload_snapshot(snapshot)
    end
  end

  @spec get_constitution_snapshot(binary()) :: ConstitutionSnapshot.t() | nil
  def get_constitution_snapshot(snapshot_id) when is_binary(snapshot_id) do
    case Repo.get(ConstitutionSnapshot, snapshot_id) do
      nil -> nil
      snapshot -> preload_snapshot(snapshot)
    end
  end

  @spec get_constitution_snapshot_by_id(binary()) :: ConstitutionSnapshot.t() | nil
  def get_constitution_snapshot_by_id(snapshot_id) when is_binary(snapshot_id) do
    get_constitution_snapshot(snapshot_id)
  end

  @spec publish_constitution_snapshot(map() | nil) ::
          {:ok, ConstitutionSnapshot.t()} | {:error, term()}
  def publish_constitution_snapshot(source \\ nil) do
    case source do
      %{} = attrs ->
        case Map.get(attrs, "proposal_id") || Map.get(attrs, :proposal_id) do
          proposal_id when is_binary(proposal_id) and proposal_id != "" ->
            apply_approved_proposal(proposal_id)

          _ ->
            Repo.transaction(fn ->
              case publish_snapshot_for_laws(source) do
                {:ok, snapshot} -> snapshot
                {:error, reason} -> Repo.rollback(reason)
              end
            end)
        end

      _ ->
        Repo.transaction(fn ->
          case publish_snapshot_for_laws(source) do
            {:ok, snapshot} -> snapshot
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  defp insert_proposal(attrs) do
    %LawProposal{}
    |> LawProposal.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, proposal} -> {:ok, Repo.preload(proposal, proposal_preloads())}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp preload_vote_result({:ok, vote}), do: {:ok, Repo.preload(vote, [:voter])}
  defp preload_vote_result(other), do: other

  defp snapshot_proposal_electorate(%LawProposal{} = proposal, role_ids) do
    now = DateTime.utc_now()

    role_rows =
      Enum.map(role_ids, fn role_id ->
        %{
          proposal_id: proposal.id,
          role_id: role_id,
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    electorate_rows =
      proposal_electorate_users(proposal, role_ids)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn user ->
        %{
          proposal_id: proposal.id,
          user_id: user.id,
          eligible_via: Atom.to_string(proposal.voting_scope),
          metadata: %{},
          inserted_at: now,
          updated_at: now
        }
      end)

    if role_rows != [] do
      Repo.insert_all(ProposalEligibleRole, role_rows, on_conflict: :nothing)
    end

    if electorate_rows != [] do
      Repo.insert_all(ProposalElector, electorate_rows, on_conflict: :nothing)
    end

    :ok
  end

  defp proposal_electorate_users(%LawProposal{voting_scope: :all_members}, _role_ids) do
    DirectoryUser
    |> where([user], user.kind == :person)
    |> order_by([user], asc: user.localpart)
    |> Repo.all()
  end

  defp proposal_electorate_users(%LawProposal{voting_scope: :role_subset}, role_ids) do
    DirectoryUser
    |> join(:inner, [user], assignment in RoleAssignment,
      on:
        assignment.user_id == user.id and
          assignment.status == :active and
          assignment.role_id in ^role_ids
    )
    |> distinct(true)
    |> select([user, _assignment], user)
    |> order_by([user, _assignment], asc: user.localpart)
    |> Repo.all()
  end

  defp proposal_electorate_users(_, _role_ids), do: []

  defp compute_proposal_results(%LawProposal{} = proposal) do
    votes = proposal.votes || []
    electors = proposal.electors || []
    rules = normalize_map(proposal.voting_rule_snapshot || %{})

    approve_count = Enum.count(votes, &(&1.choice == :approve))
    reject_count = Enum.count(votes, &(&1.choice == :reject))
    abstain_count = Enum.count(votes, &(&1.choice == :abstain))
    cast_count = length(votes)
    eligible_count = length(electors)
    turnout_percent = percentage(cast_count, eligible_count)
    quorum_threshold = numeric_rule_value(rules, "quorum_percent", 50)

    %{
      approve_count: approve_count,
      reject_count: reject_count,
      abstain_count: abstain_count,
      cast_count: cast_count,
      eligible_count: eligible_count,
      turnout_percent: turnout_percent,
      quorum_met?: turnout_percent >= quorum_threshold,
      approval_met?:
        approval_met?(rules, approve_count, reject_count, cast_count, eligible_count),
      voting_rule_snapshot: rules
    }
  end

  defp summarize_results(results) do
    Map.take(results, [
      :approve_count,
      :reject_count,
      :abstain_count,
      :cast_count,
      :eligible_count,
      :turnout_percent,
      :quorum_met?,
      :approval_met?,
      :voting_rule_snapshot
    ])
  end

  defp empty_results do
    %{
      approve_count: 0,
      reject_count: 0,
      abstain_count: 0,
      cast_count: 0,
      eligible_count: 0,
      turnout_percent: 0,
      quorum_met?: false,
      approval_met?: false,
      voting_rule_snapshot: default_voting_rule_config()
    }
  end

  defp resolved_proposal_status(%{quorum_met?: false}), do: :rejected
  defp resolved_proposal_status(%{approval_met?: true}), do: :approved
  defp resolved_proposal_status(_results), do: :rejected

  defp apply_proposal_to_law(%LawProposal{proposal_type: :create} = proposal) do
    create_law(%{
      "slug" => proposal.proposed_slug || normalize_slug(proposal.reference),
      "name" => proposal.proposed_name || proposal.reference,
      "markdown_body" => proposal.proposed_markdown_body || "",
      "law_kind" => Atom.to_string(proposal.proposed_law_kind || :general),
      "rule_config" => proposal.proposed_rule_config || %{},
      "status" => "active",
      "position" => next_law_position(),
      "version" => 1,
      "ratified_at" => proposal.resolved_at || DateTime.utc_now(),
      "metadata" => merge_metadata(proposal.metadata, %{"proposal_id" => proposal.id}),
      "created_by_id" => proposal.created_by_id,
      "updated_by_id" => proposal.resolved_by_id || proposal.created_by_id
    })
  end

  defp apply_proposal_to_law(%LawProposal{proposal_type: :amend, law_id: law_id} = proposal)
       when is_binary(law_id) do
    law = Repo.get!(Law, law_id)

    law
    |> Law.changeset(%{
      "slug" => proposal.proposed_slug || law.slug,
      "name" => proposal.proposed_name || law.name,
      "markdown_body" => proposal.proposed_markdown_body || law.markdown_body,
      "law_kind" => Atom.to_string(proposal.proposed_law_kind || law.law_kind),
      "rule_config" => proposal.proposed_rule_config || law.rule_config || %{},
      "status" => "active",
      "position" => law.position,
      "version" => law.version + 1,
      "ratified_at" => proposal.resolved_at || DateTime.utc_now(),
      "repealed_at" => nil,
      "metadata" => merge_metadata(law.metadata, proposal.metadata),
      "updated_by_id" => proposal.resolved_by_id || proposal.created_by_id
    })
    |> Repo.update()
  end

  defp apply_proposal_to_law(%LawProposal{proposal_type: :repeal, law_id: law_id} = proposal)
       when is_binary(law_id) do
    law = Repo.get!(Law, law_id)

    law
    |> Law.changeset(%{
      "status" => "repealed",
      "version" => law.version + 1,
      "repealed_at" => proposal.resolved_at || DateTime.utc_now(),
      "metadata" => merge_metadata(law.metadata, proposal.metadata),
      "updated_by_id" => proposal.resolved_by_id || proposal.created_by_id
    })
    |> Repo.update()
  end

  defp apply_proposal_to_law(%LawProposal{proposal_type: type}),
    do: {:error, {:unsupported_proposal_type, type}}

  defp publish_snapshot_for_laws(source, proposal \\ nil) do
    laws = list_active_laws_for_prompt()
    version = next_snapshot_version()

    snapshot_attrs = %{
      "version" => version,
      "prompt_text" => render_constitution_prompt(laws, version, proposal),
      "published_at" => DateTime.utc_now(),
      "proposal_id" => proposal && proposal.id,
      "metadata" => snapshot_metadata(source, proposal, laws)
    }

    case %ConstitutionSnapshot{}
         |> ConstitutionSnapshot.changeset(snapshot_attrs)
         |> Repo.insert() do
      {:ok, snapshot} -> insert_snapshot_laws(snapshot, laws)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_snapshot_laws(%ConstitutionSnapshot{} = snapshot, laws) do
    now = DateTime.utc_now()

    entries =
      laws
      |> Enum.with_index(1)
      |> Enum.map(fn {law, position} ->
        %{
          snapshot_id: snapshot.id,
          law_id: law.id,
          position: position,
          metadata: %{
            "law_slug" => law.slug,
            "law_kind" => Atom.to_string(law.law_kind)
          },
          inserted_at: now,
          updated_at: now
        }
      end)

    if entries != [] do
      Repo.insert_all(ConstitutionSnapshotLaw, entries, on_conflict: :nothing)
    end

    {:ok, preload_snapshot(snapshot)}
  end

  defp get_constitution_snapshot_by_proposal_id(proposal_id) when is_binary(proposal_id) do
    case Repo.get_by(ConstitutionSnapshot, proposal_id: proposal_id) do
      nil -> nil
      snapshot -> preload_snapshot(snapshot)
    end
  end

  defp preload_snapshot(%ConstitutionSnapshot{} = snapshot) do
    snapshot
    |> Repo.preload(
      proposal: proposal_preloads(),
      law_memberships: snapshot_law_preload_query(),
      laws: [:created_by, :updated_by]
    )
  end

  defp preload_law(%Law{} = law) do
    Repo.preload(
      law,
      [
        :created_by,
        :updated_by,
        proposals: proposal_preloads(),
        constitution_snapshots: [:proposal]
      ]
    )
  end

  defp preload_role(%Role{} = role) do
    Repo.preload(role, assignments: [:user, :role])
  end

  defp render_constitution_prompt(laws, version, proposal) do
    header =
      [
        "Company Constitution",
        "Snapshot version: #{version}",
        proposal && "Published from proposal: #{proposal.reference}"
      ]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n")

    body =
      laws
      |> Enum.map_join("\n\n", fn law ->
        [
          "Law #{law.position}: #{law.name}",
          "Slug: #{law.slug}",
          "Kind: #{Atom.to_string(law.law_kind)}",
          law.markdown_body
        ]
        |> Enum.reject(&blank?/1)
        |> Enum.join("\n")
      end)

    [header, body]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp snapshot_metadata(source, proposal, laws) do
    base =
      case source do
        %{} = attrs -> normalize_map(attrs)
        _ -> %{}
      end

    base
    |> Map.put("law_count", length(laws))
    |> maybe_put("proposal_id", proposal && proposal.id)
    |> maybe_put("proposal_reference", proposal && proposal.reference)
    |> maybe_put(
      "proposal_type",
      proposal && proposal.proposal_type && Atom.to_string(proposal.proposal_type)
    )
  end

  defp proposal_preloads do
    [
      :law,
      :created_by,
      :resolved_by,
      votes: vote_preload_query(),
      electors: elector_preload_query(),
      eligible_role_links: eligible_role_preload_query()
    ]
  end

  defp vote_preload_query do
    from vote in LawVote,
      order_by: [asc: vote.cast_at, asc: vote.inserted_at],
      preload: [:voter]
  end

  defp elector_preload_query do
    from elector in ProposalElector,
      order_by: [asc: elector.inserted_at],
      preload: [:user]
  end

  defp eligible_role_preload_query do
    from link in ProposalEligibleRole,
      order_by: [asc: link.inserted_at],
      preload: [:role]
  end

  defp snapshot_law_preload_query do
    from membership in ConstitutionSnapshotLaw,
      order_by: [asc: membership.position, asc: membership.inserted_at],
      preload: [:law]
  end

  defp maybe_filter_law_status(query, opts) do
    case option_get(opts, :status) do
      nil ->
        query

      "" ->
        query

      status ->
        where(query, [law], law.status == ^normalize_enum(status, Law.statuses(), :active))
    end
  end

  defp maybe_filter_law_kind(query, opts) do
    case option_get(opts, :law_kind) do
      nil ->
        query

      "" ->
        query

      law_kind ->
        where(query, [law], law.law_kind == ^normalize_enum(law_kind, Law.law_kinds(), :general))
    end
  end

  defp maybe_search_laws(query, nil), do: query

  defp maybe_search_laws(query, value) do
    case String.trim(to_string(value)) do
      "" ->
        query

      term ->
        like = "%#{term}%"

        where(
          query,
          [law],
          ilike(law.slug, ^like) or
            ilike(law.name, ^like) or
            ilike(fragment("coalesce(?, '')", law.markdown_body), ^like)
        )
    end
  end

  defp maybe_filter_role_enabled(query, opts) do
    case option_get(opts, :enabled) do
      nil -> query
      "" -> query
      enabled -> where(query, [role], role.enabled == ^truthy?(enabled))
    end
  end

  defp maybe_search_roles(query, nil), do: query

  defp maybe_search_roles(query, value) do
    case String.trim(to_string(value)) do
      "" ->
        query

      term ->
        like = "%#{term}%"

        where(
          query,
          [role],
          ilike(role.slug, ^like) or
            ilike(role.name, ^like) or
            ilike(fragment("coalesce(?, '')", role.description), ^like)
        )
    end
  end

  defp maybe_filter_assignment_status(query, opts) do
    case option_get(opts, :status) do
      nil ->
        query

      "" ->
        query

      status ->
        where(
          query,
          [assignment],
          assignment.status == ^normalize_enum(status, RoleAssignment.statuses(), :active)
        )
    end
  end

  defp maybe_filter_proposal_status(query, opts) do
    case option_get(opts, :status) do
      nil ->
        query

      "" ->
        query

      status ->
        where(
          query,
          [proposal],
          proposal.status == ^normalize_enum(status, LawProposal.statuses(), :open)
        )
    end
  end

  defp maybe_filter_proposal_type(query, opts) do
    case option_get(opts, :proposal_type) do
      nil ->
        query

      "" ->
        query

      proposal_type ->
        where(
          query,
          [proposal],
          proposal.proposal_type ==
            ^normalize_enum(proposal_type, LawProposal.proposal_types(), :create)
        )
    end
  end

  defp maybe_filter_proposal_room(query, nil), do: query
  defp maybe_filter_proposal_room(query, ""), do: query

  defp maybe_filter_proposal_room(query, room_id),
    do: where(query, [proposal], proposal.room_id == ^room_id)

  defp maybe_search_proposals(query, nil), do: query

  defp maybe_search_proposals(query, value) do
    case String.trim(to_string(value)) do
      "" ->
        query

      term ->
        like = "%#{term}%"

        where(
          query,
          [proposal],
          ilike(proposal.reference, ^like) or
            ilike(fragment("coalesce(?, '')", proposal.proposed_slug), ^like) or
            ilike(fragment("coalesce(?, '')", proposal.proposed_name), ^like) or
            ilike(fragment("coalesce(?, '')", proposal.reason), ^like)
        )
    end
  end

  defp maybe_filter_snapshot_proposal(query, opts) do
    case option_get(opts, :proposal_id) do
      nil -> query
      "" -> query
      proposal_id -> where(query, [snapshot], snapshot.proposal_id == ^proposal_id)
    end
  end

  defp option_get(opts, key, default \\ nil)

  defp option_get(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp option_get(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end

  defp option_get(_opts, _key, default), do: default

  defp resolve_voting_rule_snapshot do
    case current_voting_policy_law() do
      %Law{rule_config: rule_config} when is_map(rule_config) ->
        Map.merge(default_voting_rule_config(), normalize_map(rule_config))

      _ ->
        default_voting_rule_config()
    end
  end

  defp normalize_rule_snapshot(attrs) do
    attrs
    |> Map.get("voting_rule_snapshot", %{})
    |> normalize_map()
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp current_voting_policy_law do
    Law
    |> where([law], law.status == :active and law.law_kind == :voting_policy)
    |> order_by([law], desc: law.ratified_at, desc: law.inserted_at, desc: law.version)
    |> limit(1)
    |> Repo.one()
  end

  defp resolve_law_identifier(nil), do: nil
  defp resolve_law_identifier(""), do: nil

  defp resolve_law_identifier(identifier) when is_binary(identifier) do
    trimmed = String.trim(identifier)

    case Ecto.UUID.cast(trimmed) do
      {:ok, uuid} ->
        uuid

      :error ->
        case Repo.get_by(Law, slug: normalize_slug(trimmed)) do
          %Law{} = law -> law.id
          nil -> nil
        end
    end
  end

  defp resolve_law_identifier(identifier),
    do: identifier |> to_string() |> resolve_law_identifier()

  defp resolve_proposed_slug(attrs) do
    attrs
    |> Map.get("proposed_slug")
    |> blank_to_nil()
    |> case do
      nil ->
        attrs
        |> Map.get("proposed_name", Map.get(attrs, "reference", "law"))
        |> normalize_slug()

      slug ->
        normalize_slug(slug)
    end
  end

  defp resolve_proposed_name(attrs) do
    attrs
    |> Map.get("proposed_name")
    |> blank_to_nil()
    |> case do
      nil -> Map.get(attrs, "reference", "Governance Law")
      name -> String.trim(name)
    end
  end

  defp proposal_role_ids(attrs) do
    attrs
    |> Map.get("eligible_role_ids", [])
    |> List.wrap()
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp proposal_type(attrs) do
    normalize_enum(Map.get(attrs, "proposal_type"), LawProposal.proposal_types(), :create)
  end

  defp voting_scope(attrs) do
    normalize_enum(Map.get(attrs, "voting_scope"), LawProposal.voting_scopes(), :all_members)
  end

  defp maybe_put_law_timestamps(attrs) do
    case normalize_enum(Map.get(attrs, "status"), Law.statuses(), :active) do
      :active -> Map.put_new(attrs, "ratified_at", DateTime.utc_now())
      :repealed -> Map.put_new(attrs, "repealed_at", DateTime.utc_now())
      _ -> attrs
    end
  end

  defp approval_met?(rules, approve_count, reject_count, cast_count, eligible_count) do
    threshold = numeric_rule_value(rules, "approval_threshold_percent", 50)

    case Map.get(rules, "approval_mode", "majority_cast") do
      mode when mode in ["majority", "majority_cast", "majority_of_cast"] ->
        cast_count > 0 and approve_count > reject_count

      mode when mode in ["supermajority", "supermajority_cast", "threshold_percent"] ->
        positive_votes = max(approve_count + reject_count, 1)
        approve_count * 100 >= positive_votes * threshold

      "majority_all_eligible" ->
        approve_count * 2 > max(eligible_count, 1)

      _ ->
        cast_count > 0 and approve_count > reject_count
    end
  end

  defp voting_window_hours(rules), do: numeric_rule_value(rules, "voting_window_hours", 72)

  defp numeric_rule_value(map, key, default) do
    case Map.get(map, key, default) do
      value when is_integer(value) ->
        value

      value when is_float(value) ->
        round(value)

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, _} -> parsed
          :error -> default
        end

      _ ->
        default
    end
  end

  defp percentage(_part, total) when total in [nil, 0], do: 0

  defp percentage(part, total) when is_integer(part) and is_integer(total),
    do: round(part * 100 / total)

  defp merge_metadata(left, right) do
    Map.merge(normalize_map(left || %{}), normalize_map(right || %{}))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp generate_reference(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    "#{prefix}-#{suffix}"
  end

  defp next_law_position do
    (Repo.aggregate(Law, :max, :position) || 0) + 1
  end

  defp next_snapshot_version do
    (Repo.aggregate(ConstitutionSnapshot, :max, :version) || 0) + 1
  end

  defp normalize_map(%{} = map) when not is_struct(map) do
    Enum.into(map, %{}, fn {key, value} ->
      {normalize_key(key), normalize_value(value)}
    end)
  end

  defp normalize_map(_), do: %{}

  defp normalize_value(%{} = map) when not is_struct(map), do: normalize_map(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp normalize_slug(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/^-+|-+$/u, "")
  end

  defp normalize_enum(value, allowed, default) when is_atom(value) do
    if value in allowed, do: value, else: default
  end

  defp normalize_enum(value, allowed, default) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    Enum.find(allowed, default, fn candidate ->
      Atom.to_string(candidate) == normalized
    end)
  end

  defp normalize_enum(_, _allowed, default), do: default

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(nil), do: true
  defp blank?(_), do: false

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value |> to_string() |> blank_to_nil()

  defp truthy?(value) when is_boolean(value), do: value

  defp truthy?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]

  defp truthy?(value) when is_integer(value), do: value != 0
  defp truthy?(_), do: false
end
