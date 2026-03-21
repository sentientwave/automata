defmodule SentientwaveAutomata.Governance.Workflow do
  @moduledoc """
  Durable governance lifecycle boundary for proposals and votes.
  """

  import Ecto.Query, warn: false
  require Logger

  alias SentientwaveAutomata.Governance

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

  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.DirectoryUser
  alias SentientwaveAutomata.Repo

  @spec handle_command(map()) :: {:ok, map()} | {:error, term()} | :ignore
  def handle_command(%{proposal_type: _} = command), do: open_proposal(command)
  def handle_command(%{choice: _} = command), do: cast_vote(command)
  def handle_command(_command), do: :ignore

  @spec open_proposal(map()) :: {:ok, LawProposal.t()} | {:error, term()}
  def open_proposal(command) when is_map(command) do
    with {:ok, actor} <- resolve_actor(command),
         true <- allowed_to_open?(actor) || {:error, :not_authorized},
         {:ok, proposal} <- insert_proposal(command, actor),
         {:ok, proposal} <- maybe_start_workflow(proposal),
         :ok <- announce_proposal_opened(proposal, actor) do
      {:ok, preload_proposal(proposal)}
    end
  end

  @spec cast_vote(map()) :: {:ok, LawVote.t()} | {:error, term()}
  def cast_vote(command) when is_map(command) do
    with {:ok, proposal} <- resolve_proposal(command),
         true <- proposal.status == :open || {:error, :proposal_closed},
         {:ok, actor} <- resolve_actor(command),
         true <- eligible_voter?(proposal, actor) || {:error, :not_eligible},
         {:ok, vote} <- record_vote(proposal, actor, command),
         :ok <- signal_vote_cast(proposal, vote),
         :ok <- announce_vote_cast(proposal, vote, actor) do
      {:ok, vote}
    end
  end

  @spec resolve_proposal(map() | binary()) :: {:ok, LawProposal.t()} | {:error, term()}
  def resolve_proposal(%{} = attrs) do
    with {:ok, proposal} <- resolve_proposal_record(attrs),
         true <- proposal.status == :open || {:error, :proposal_closed},
         {:ok, resolved} <- finalize_proposal(proposal, attrs),
         :ok <- announce_resolution(resolved) do
      {:ok, resolved}
    end
  end

  def resolve_proposal(reference) when is_binary(reference) do
    resolve_proposal(%{"reference" => reference})
  end

  @spec current_constitution_snapshot() :: ConstitutionSnapshot.t() | nil
  def current_constitution_snapshot do
    snapshot_preloads = [:proposal, laws: [:created_by, :updated_by], law_memberships: :law]

    ConstitutionSnapshot
    |> preload(^snapshot_preloads)
    |> order_by([s], desc: s.version, desc: s.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec proposal_results(LawProposal.t() | binary()) :: map() | {:error, term()}
  def proposal_results(%LawProposal{} = proposal) do
    proposal = Repo.preload(proposal, [:votes, :electors, :eligible_role_links])

    votes =
      Enum.sort_by(proposal.votes, &{&1.cast_at || ~U[1970-01-01 00:00:00Z], &1.inserted_at})

    approve_count = Enum.count(votes, &(&1.choice == :approve))
    reject_count = Enum.count(votes, &(&1.choice == :reject))
    abstain_count = Enum.count(votes, &(&1.choice == :abstain))
    cast_count = length(votes)
    eligible_count = length(proposal.electors)
    turnout_percent = percentage(cast_count, max(eligible_count, 1))
    rule = voting_rule_snapshot(proposal)

    %{
      proposal_id: proposal.id,
      approve_count: approve_count,
      reject_count: reject_count,
      abstain_count: abstain_count,
      cast_count: cast_count,
      eligible_count: eligible_count,
      turnout_percent: turnout_percent,
      quorum_percent: integer_map_value(rule, "quorum_percent", 50),
      approval_percent: integer_map_value(rule, "approval_threshold_percent", 50),
      approval_mode: string_map_value(rule, "approval_mode", "majority_cast"),
      quorum_met?: turnout_percent >= integer_map_value(rule, "quorum_percent", 50),
      approval_met?: approval_met?(rule, approve_count, reject_count, eligible_count),
      voting_rule_snapshot: rule
    }
  end

  def proposal_results(reference) when is_binary(reference) do
    case resolve_proposal_record(%{"reference" => reference}) do
      {:ok, proposal} -> proposal_results(proposal)
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_proposal(command, actor) do
    now = DateTime.utc_now()
    rule = voting_rule_snapshot()
    closes_at = resolve_closes_at(command, now, rule)
    proposal_attrs = proposal_attrs(command, actor, now, closes_at, rule)

    Repo.transaction(fn ->
      with {:ok, proposal} <-
             %LawProposal{}
             |> LawProposal.changeset(proposal_attrs)
             |> Repo.insert(),
           :ok <- insert_snapshot_links(proposal, command) do
        proposal
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, proposal} -> {:ok, proposal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_start_workflow(%LawProposal{} = proposal) do
    input = %{
      proposal_id: proposal.id,
      reference: proposal.reference,
      room_id: proposal.room_id,
      proposal_type: proposal.proposal_type,
      opens_at: proposal.opened_at,
      closes_at: proposal.closes_at
    }

    case temporal_adapter().start_workflow("governance_proposal_workflow", input, []) do
      {:ok, %{workflow_id: workflow_id}} when is_binary(workflow_id) and workflow_id != "" ->
        proposal
        |> Ecto.Changeset.change(%{workflow_id: workflow_id})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated}
          {:error, changeset} -> {:error, changeset}
        end

      {:ok, _} ->
        {:ok, proposal}

      {:error, reason} ->
        Logger.warning(
          "governance_workflow_start_failed proposal_id=#{proposal.id} reference=#{proposal.reference} reason=#{inspect(reason)}"
        )

        {:ok, proposal}
    end
  end

  defp record_vote(%LawProposal{} = proposal, %DirectoryUser{} = actor, command) do
    attrs = %{
      choice: command.choice,
      room_id: command.room_id,
      message_id: command.message_id,
      raw_event: Map.get(command, :raw_event, %{}),
      metadata: Map.merge(command_metadata(command), %{"source" => "matrix_governance"}),
      cast_at: DateTime.utc_now()
    }

    Governance.cast_vote(proposal.id, actor.id, attrs)
  end

  defp finalize_proposal(%LawProposal{} = proposal, attrs) do
    results = proposal_results(proposal)
    final_status = resolve_status(results)
    resolved_at = DateTime.utc_now()
    resolved_by_id = resolved_by_id(attrs)

    with {:ok, updated} <-
           proposal
           |> LawProposal.changeset(%{
             status: final_status,
             resolved_at: resolved_at,
             resolved_by_id: resolved_by_id
           })
           |> Repo.update() do
      case final_status do
        :approved ->
          with {:ok, _applied} <- apply_approved_proposal(updated, attrs),
               {:ok, _snapshot} <- publish_constitution_snapshot(updated, attrs) do
            {:ok, Repo.preload(updated, [:votes, :electors, :eligible_role_links, :law])}
          end

        _ ->
          {:ok, Repo.preload(updated, [:votes, :electors, :eligible_role_links, :law])}
      end
    end
  end

  defp apply_approved_proposal(%LawProposal{} = proposal, _attrs) do
    case proposal.proposal_type do
      :create -> create_law_from_proposal(proposal)
      :amend -> amend_law_from_proposal(proposal)
      :repeal -> repeal_law_from_proposal(proposal)
    end
  end

  defp create_law_from_proposal(%LawProposal{} = proposal) do
    attrs = %{
      slug: proposal.proposed_slug,
      name: proposal.proposed_name,
      markdown_body: proposal.proposed_markdown_body,
      law_kind: proposal.proposed_law_kind,
      rule_config: proposal.proposed_rule_config,
      status: :active,
      position: next_law_position(),
      version: 1,
      ratified_at: DateTime.utc_now(),
      created_by_id: proposal.created_by_id,
      updated_by_id: proposal.resolved_by_id || proposal.created_by_id,
      metadata: Map.merge(proposal.metadata || %{}, %{"proposal_id" => proposal.id})
    }

    %Law{}
    |> Law.changeset(attrs)
    |> Repo.insert()
  end

  defp amend_law_from_proposal(%LawProposal{} = proposal) do
    with {:ok, law} <- resolve_target_law(proposal) do
      attrs = %{
        slug: proposal.proposed_slug || law.slug,
        name: proposal.proposed_name || law.name,
        markdown_body: proposal.proposed_markdown_body || law.markdown_body,
        law_kind: proposal.proposed_law_kind || law.law_kind,
        rule_config: proposal.proposed_rule_config || law.rule_config,
        status: :active,
        position: law.position,
        version: law.version + 1,
        ratified_at: DateTime.utc_now(),
        repealed_at: nil,
        updated_by_id: proposal.resolved_by_id || proposal.created_by_id,
        metadata: Map.merge(law.metadata || %{}, %{"amended_by_proposal_id" => proposal.id})
      }

      law
      |> Law.changeset(attrs)
      |> Repo.update()
    end
  end

  defp repeal_law_from_proposal(%LawProposal{} = proposal) do
    with {:ok, law} <- resolve_target_law(proposal) do
      attrs = %{
        status: :repealed,
        version: law.version + 1,
        repealed_at: DateTime.utc_now(),
        updated_by_id: proposal.resolved_by_id || proposal.created_by_id,
        metadata: Map.merge(law.metadata || %{}, %{"repealed_by_proposal_id" => proposal.id})
      }

      law
      |> Law.changeset(attrs)
      |> Repo.update()
    end
  end

  defp publish_constitution_snapshot(%LawProposal{} = proposal, attrs) do
    laws = active_laws_for_snapshot()
    version = next_snapshot_version()
    prompt_text = render_constitution_prompt(laws)
    published_at = DateTime.utc_now()

    Repo.transaction(fn ->
      snapshot =
        %ConstitutionSnapshot{}
        |> ConstitutionSnapshot.changeset(%{
          version: version,
          prompt_text: prompt_text,
          published_at: published_at,
          proposal_id: proposal.id,
          metadata: Map.merge(command_metadata(attrs), %{"law_count" => length(laws)})
        })
        |> Repo.insert!()

      Enum.with_index(laws, 1)
      |> Enum.each(fn {law, position} ->
        %ConstitutionSnapshotLaw{}
        |> ConstitutionSnapshotLaw.changeset(%{
          snapshot_id: snapshot.id,
          law_id: law.id,
          position: position,
          metadata: %{"law_slug" => law.slug, "law_kind" => Atom.to_string(law.law_kind)}
        })
        |> Repo.insert!()
      end)

      snapshot
      |> Repo.preload(proposal: :created_by, laws: :created_by, law_memberships: :law)
    end)
    |> case do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_snapshot_links(%LawProposal{} = proposal, command) do
    with :ok <- insert_role_links(proposal, command),
         :ok <- insert_electors(proposal, command) do
      :ok
    end
  end

  defp insert_role_links(%LawProposal{} = proposal, command) do
    case voting_scope(command) do
      :role_subset ->
        role_ids = eligible_role_ids(command)

        if role_ids == [] do
          {:error, :missing_eligible_roles}
        else
          Enum.each(role_ids, fn role_id ->
            %ProposalEligibleRole{}
            |> ProposalEligibleRole.changeset(%{
              proposal_id: proposal.id,
              role_id: role_id,
              metadata: command_metadata(command)
            })
            |> Repo.insert!()
          end)

          :ok
        end

      _ ->
        :ok
    end
  end

  defp insert_electors(%LawProposal{} = proposal, command) do
    case voting_scope(command) do
      :all_members ->
        users =
          DirectoryUser
          |> where([u], u.kind == :person)
          |> Repo.all()

        Enum.each(users, fn user ->
          %ProposalElector{}
          |> ProposalElector.changeset(%{
            proposal_id: proposal.id,
            user_id: user.id,
            eligible_via: "all_members",
            metadata: command_metadata(command)
          })
          |> Repo.insert!()
        end)

        :ok

      :role_subset ->
        role_ids = eligible_role_ids(command)

        if role_ids == [] do
          {:error, :missing_eligible_roles}
        else
          users_with_active_roles(role_ids)
          |> Enum.each(fn user ->
            %ProposalElector{}
            |> ProposalElector.changeset(%{
              proposal_id: proposal.id,
              user_id: user.id,
              eligible_via: "role_subset",
              metadata: Map.merge(command_metadata(command), %{"role_ids" => role_ids})
            })
            |> Repo.insert!()
          end)

          :ok
        end

      _ ->
        :ok
    end
  end

  defp users_with_active_roles(role_ids) do
    RoleAssignment
    |> join(:inner, [a], u in DirectoryUser, on: u.id == a.user_id)
    |> join(:inner, [a, _u], r in Role, on: r.id == a.role_id)
    |> where([a, _u, r], a.status == :active and r.enabled == true and a.role_id in ^role_ids)
    |> distinct(true)
    |> select([_a, u, _r], u)
    |> Repo.all()
  end

  defp allowed_to_open?(%DirectoryUser{} = actor) do
    actor.kind == :person or actor.admin
  end

  defp allowed_to_open?(_), do: false

  defp eligible_voter?(%LawProposal{} = proposal, %DirectoryUser{} = actor) do
    Repo.exists?(
      from e in ProposalElector,
        where: e.proposal_id == ^proposal.id and e.user_id == ^actor.id
    )
  end

  defp resolve_actor(%{sender_mxid: sender_mxid}) when is_binary(sender_mxid) do
    localpart = mxid_localpart(sender_mxid)

    case localpart && Directory.get_user_record(localpart) do
      %DirectoryUser{} = user -> {:ok, user}
      _ -> {:error, :unknown_sender}
    end
  end

  defp resolve_actor(%{"sender_mxid" => sender_mxid}) when is_binary(sender_mxid) do
    resolve_actor(%{sender_mxid: sender_mxid})
  end

  defp resolve_actor(_), do: {:error, :missing_sender}

  defp resolve_target_law(%LawProposal{law_id: law_id}) when is_binary(law_id) do
    case Repo.get(Law, law_id) do
      %Law{} = law -> {:ok, law}
      nil -> {:error, :not_found}
    end
  end

  defp resolve_target_law(%LawProposal{proposal_type: proposal_type})
       when proposal_type in [:amend, :repeal],
       do: {:error, :missing_target_law}

  defp resolve_target_law(%LawProposal{} = proposal) do
    cond do
      is_binary(proposal.proposed_slug) and proposal.proposed_slug != "" ->
        case Repo.get_by(Law, slug: proposal.proposed_slug) do
          %Law{} = law -> {:ok, law}
          nil -> {:error, :not_found}
        end

      true ->
        {:error, :missing_target_law}
    end
  end

  defp resolve_target_law(_proposal), do: {:error, :missing_target_law}

  defp proposal_attrs(command, actor, now, closes_at, rule) do
    payload = Map.get(command, :proposal, %{})

    proposal_type =
      normalize_atom(
        Map.get(command, :proposal_type) || payload_value(payload, ["proposal_type"], :create)
      )

    %{
      reference:
        Map.get(command, :reference) ||
          payload_value(payload, ["reference"], generate_reference()),
      proposal_type: proposal_type,
      law_id: resolve_law_id(command, payload),
      status: :open,
      proposed_slug:
        Map.get(command, :proposed_slug) ||
          payload_value(
            payload,
            ["proposed_slug", "slug"],
            default_proposed_slug(payload, command)
          ),
      proposed_name:
        Map.get(command, :proposed_name) ||
          payload_value(
            payload,
            ["proposed_name", "name"],
            default_proposed_name(payload, command)
          ),
      proposed_markdown_body:
        Map.get(command, :proposed_markdown_body) ||
          payload_value(payload, ["proposed_markdown_body", "markdown_body", "body"], nil),
      proposed_law_kind:
        Map.get(command, :proposed_law_kind) ||
          normalize_atom(payload_value(payload, ["proposed_law_kind", "law_kind"], :general)),
      proposed_rule_config:
        Map.get(command, :proposed_rule_config) ||
          normalize_map(payload_value(payload, ["proposed_rule_config", "rule_config"], %{})),
      reason:
        Map.get(command, :reason) ||
          payload_value(payload, ["reason"], nil),
      voting_scope:
        normalize_atom(
          Map.get(command, :voting_scope) ||
            payload_value(payload, ["voting_scope"], :all_members)
        ),
      voting_rule_snapshot: rule,
      opened_at: now,
      closes_at: closes_at,
      room_id: Map.get(command, :room_id),
      proposal_message_id: Map.get(command, :message_id),
      raw_event: Map.get(command, :raw_event, %{}),
      workflow_id: nil,
      metadata:
        Map.merge(command_metadata(command), %{
          "matrix_sender_mxid" => Map.get(command, :sender_mxid),
          "proposal_type" => to_string(proposal_type),
          "eligible_role_ids" => eligible_role_ids(command)
        }),
      created_by_id: actor.id
    }
  end

  defp resolve_law_id(command, payload) do
    law_id =
      Map.get(command, :law_id) ||
        Map.get(command, :target_ref) ||
        Map.get(command, "target_ref") ||
        payload_value(payload, ["law_id", "law_slug", "target_ref"], nil)

    cond do
      is_binary(law_id) and law_id != "" -> law_id
      true -> resolve_target_law_by_payload(payload)
    end
  end

  defp resolve_target_law_by_payload(payload) do
    slug = payload_value(payload, ["law_id", "law_slug", "target_ref"], nil)

    if is_binary(slug) and slug != "" do
      case Ecto.UUID.cast(slug) do
        {:ok, uuid} ->
          case Repo.get(Law, uuid) do
            %Law{} = law -> law.id
            nil -> nil
          end

        :error ->
          case Repo.get_by(Law, slug: slug) do
            %Law{} = law -> law.id
            nil -> nil
          end
      end
    else
      nil
    end
  end

  defp default_proposed_slug(payload, command) do
    payload_value(payload, ["proposed_slug", "slug"], nil) ||
      payload_value(payload, ["proposed_name", "name"], nil) ||
      Map.get(command, :reference) ||
      generate_reference() |> slugify()
  end

  defp default_proposed_name(payload, command) do
    payload_value(payload, ["proposed_name", "name"], nil) ||
      payload_value(payload, ["proposed_slug", "slug"], nil) ||
      Map.get(command, :reference) ||
      "Governance Law"
  end

  defp announce_proposal_opened(proposal, actor),
    do: maybe_announce_proposal_opened(proposal, actor)

  defp maybe_announce_proposal_opened(%LawProposal{} = proposal, actor) do
    message =
      [
        "Proposal opened: #{proposal.reference}",
        "Type: #{proposal.proposal_type}",
        "Scope: #{proposal.voting_scope}",
        "Closes: #{proposal.closes_at}"
      ]
      |> Enum.join("\n")

    post_matrix_message(proposal.room_id, message, %{
      kind: "proposal_opened",
      proposal_id: proposal.id,
      proposal_reference: proposal.reference,
      requested_by: actor.localpart
    })
  end

  defp announce_vote_cast(%LawProposal{} = proposal, %LawVote{} = vote, actor) do
    message =
      "Vote recorded: #{actor.display_name || actor.localpart} -> #{vote.choice} on #{proposal.reference}"

    post_matrix_message(proposal.room_id, message, %{
      kind: "vote_cast",
      proposal_id: proposal.id,
      proposal_reference: proposal.reference,
      vote_id: vote.id,
      voter_id: actor.id
    })
  end

  defp announce_resolution(%LawProposal{} = proposal) do
    message = "Proposal resolved: #{proposal.reference} (#{proposal.status})"

    post_matrix_message(proposal.room_id, message, %{
      kind: "proposal_resolved",
      proposal_id: proposal.id,
      proposal_reference: proposal.reference,
      status: Atom.to_string(proposal.status)
    })
  end

  defp post_matrix_message(nil, _message, _metadata), do: :ok

  defp post_matrix_message(room_id, message, metadata)
       when is_binary(room_id) and room_id != "" do
    case matrix_adapter().post_message(room_id, message, metadata) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("governance_matrix_post_failed room=#{room_id} reason=#{inspect(reason)}")

        :ok
    end
  end

  defp signal_vote_cast(%LawProposal{} = proposal, %LawVote{} = vote) do
    maybe_signal_workflow(proposal, "vote_cast", %{
      vote_id: vote.id,
      choice: Atom.to_string(vote.choice),
      voter_id: vote.voter_id,
      message_id: vote.message_id,
      room_id: vote.room_id
    })
  end

  defp maybe_signal_workflow(%LawProposal{workflow_id: nil}, _signal, _payload), do: :ok

  defp maybe_signal_workflow(%LawProposal{workflow_id: workflow_id}, signal, payload)
       when is_binary(workflow_id) and workflow_id != "" do
    case temporal_adapter().signal_workflow(workflow_id, signal, payload) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "governance_workflow_signal_failed workflow_id=#{workflow_id} signal=#{signal} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp maybe_signal_workflow(_proposal, _signal, _payload), do: :ok

  defp command_metadata(command) do
    Map.get(command, :metadata, %{})
    |> normalize_map()
  end

  defp active_laws_for_snapshot do
    Law
    |> where([l], l.status == :active)
    |> order_by([l], asc: l.position, asc: l.version, asc: l.name, asc: l.slug)
    |> Repo.all()
  end

  defp next_law_position do
    case Repo.aggregate(Law, :max, :position) do
      nil -> 1
      position -> position + 1
    end
  end

  defp next_snapshot_version do
    case Repo.aggregate(ConstitutionSnapshot, :max, :version) do
      nil -> 1
      version -> version + 1
    end
  end

  defp resolve_voting_rule_snapshot do
    default = Governance.default_voting_rule_config()

    case current_voting_policy_law() do
      %Law{rule_config: config} when is_map(config) ->
        Map.merge(default, normalize_map(config))

      _ ->
        default
    end
  end

  defp voting_rule_snapshot(), do: resolve_voting_rule_snapshot()

  defp voting_rule_snapshot(%LawProposal{voting_rule_snapshot: snapshot}) when is_map(snapshot) do
    Map.merge(Governance.default_voting_rule_config(), normalize_map(snapshot))
  end

  defp voting_rule_snapshot(_), do: Governance.default_voting_rule_config()

  defp current_voting_policy_law do
    Law
    |> where([l], l.status == :active and l.law_kind == :voting_policy)
    |> order_by([l], desc: l.position, desc: l.version, desc: l.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp approval_met?(rule, approve_count, reject_count, eligible_count) do
    approval_mode = string_map_value(rule, "approval_mode", "majority_cast")
    threshold = integer_map_value(rule, "approval_threshold_percent", 50)

    case approval_mode do
      "majority_cast" ->
        approve_count > reject_count

      "supermajority_cast" ->
        total = max(approve_count + reject_count, 1)
        approve_count * 100 >= total * threshold

      "majority_all_eligible" ->
        approve_count * 2 > max(eligible_count, 1)

      _ ->
        approve_count > reject_count
    end
  end

  defp resolve_status(%{quorum_met?: false}), do: :rejected
  defp resolve_status(%{approval_met?: true}), do: :approved
  defp resolve_status(_), do: :rejected

  defp resolve_proposal_record(attrs) when is_map(attrs) do
    reference =
      Map.get(attrs, :reference) ||
        Map.get(attrs, "reference") ||
        Map.get(attrs, :proposal_reference) ||
        Map.get(attrs, "proposal_reference")

    if is_binary(reference) and reference != "" do
      case Repo.get_by(LawProposal, reference: reference) do
        %LawProposal{} = proposal ->
          {:ok, Repo.preload(proposal, [:votes, :electors, :eligible_role_links, :law])}

        nil ->
          {:error, :not_found}
      end
    else
      {:error, :missing_reference}
    end
  end

  defp mxid_localpart(mxid) when is_binary(mxid) do
    mxid
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp mxid_localpart(_), do: nil

  defp temporal_adapter do
    Application.get_env(
      :sentientwave_automata,
      :temporal_adapter,
      SentientwaveAutomata.Adapters.Temporal.Local
    )
  end

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp normalize_id_list(nil), do: []
  defp normalize_id_list([]), do: []

  defp normalize_id_list(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_id_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> normalize_id_list()
  end

  defp normalize_id_list(value), do: [value |> to_string() |> String.trim()]

  defp eligible_role_ids(command) do
    command
    |> Map.get(:eligible_role_ids, Map.get(command, "eligible_role_ids", []))
    |> normalize_id_list()
  end

  defp voting_scope(command) do
    command
    |> Map.get(:voting_scope, Map.get(command, "voting_scope"))
    |> case do
      nil ->
        command
        |> Map.get(:proposal, %{})
        |> payload_value(["voting_scope"], :all_members)
        |> normalize_atom()

      value ->
        normalize_atom(value)
    end
  end

  defp normalize_map(value) when is_map(value), do: stringify_keys(value)
  defp normalize_map(_), do: %{}

  defp stringify_keys(map) do
    Enum.into(map, %{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {to_string(key), value}
    end)
  end

  defp payload_value(map, keys, default) when is_map(map) do
    Enum.find_value(keys, default, fn key ->
      cond do
        Map.has_key?(map, key) ->
          Map.get(map, key)

        is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
          Map.get(map, Atom.to_string(key))

        is_binary(key) and Map.has_key?(map, String.to_atom(key)) ->
          Map.get(map, String.to_atom(key))

        true ->
          nil
      end
    end)
  rescue
    _ -> default
  end

  defp payload_value(_map, _keys, default), do: default

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    case String.trim(value) do
      "active" -> :active
      "repealed" -> :repealed
      "general" -> :general
      "voting_policy" -> :voting_policy
      "create" -> :create
      "amend" -> :amend
      "repeal" -> :repeal
      "open" -> :open
      "approved" -> :approved
      "rejected" -> :rejected
      "cancelled" -> :cancelled
      "all_members" -> :all_members
      "role_subset" -> :role_subset
      "approve" -> :approve
      "reject" -> :reject
      "abstain" -> :abstain
      "majority_cast" -> "majority_cast"
      "supermajority_cast" -> "supermajority_cast"
      "majority_all_eligible" -> "majority_all_eligible"
      other -> other
    end
  end

  defp normalize_atom(value), do: value

  defp integer_map_value(map, key, default) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {parsed, _} -> parsed
          :error -> default
        end

      _ ->
        default
    end
  end

  defp string_map_value(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      value when is_atom(value) -> Atom.to_string(value)
      _ -> default
    end
  end

  defp resolve_by_id(attrs) do
    Map.get(attrs, :resolved_by_id) ||
      Map.get(attrs, "resolved_by_id")
  end

  defp resolved_by_id(attrs), do: resolve_by_id(attrs)

  defp resolve_closes_at(attrs, now, rule) do
    value =
      Map.get(attrs, :closes_at) ||
        Map.get(attrs, "closes_at") ||
        Map.get(attrs, :closing_at) ||
        Map.get(attrs, "closing_at")

    case normalize_datetime(value) do
      %DateTime{} = dt -> dt
      _ -> DateTime.add(now, integer_map_value(rule, "voting_window_hours", 72), :hour)
    end
  end

  defp normalize_datetime(%DateTime{} = dt), do: dt

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp normalize_datetime(_), do: nil

  defp percentage(0, _total), do: 0

  defp percentage(part, total) when is_integer(part) and is_integer(total) and total > 0 do
    round(part * 100 / total)
  end

  defp generate_reference do
    "LAW-" <>
      (Ecto.UUID.generate()
       |> String.replace("-", "")
       |> String.slice(0, 8)
       |> String.upcase())
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/^-+|-+$/u, "")
  end

  defp render_constitution_prompt(laws) do
    header = [
      "# Company Constitution",
      "",
      "The following laws are binding for all agent reasoning, planning, and tool use."
    ]

    law_sections =
      case laws do
        [] ->
          ["## No active laws", "", "No active laws are currently published."]

        _ ->
          Enum.flat_map(laws, fn law ->
            [
              "## #{law.position}. #{law.name}",
              "Slug: #{law.slug}",
              "Kind: #{law.law_kind}",
              "Version: #{law.version}",
              "",
              law.markdown_body,
              ""
            ]
          end)
      end

    Enum.join(header ++ law_sections, "\n")
  end

  defp preload_proposal(%LawProposal{} = proposal) do
    Repo.preload(proposal, [
      :votes,
      :electors,
      :eligible_role_links,
      :law,
      :created_by,
      :resolved_by
    ])
  end
end
