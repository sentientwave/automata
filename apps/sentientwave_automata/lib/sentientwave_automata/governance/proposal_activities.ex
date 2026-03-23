defmodule SentientwaveAutomata.Governance.ProposalActivities do
  @moduledoc """
  Temporal activity entrypoint for governance proposal workflows.
  """

  use TemporalSdk.Activity

  alias SentientwaveAutomata.Governance
  alias SentientwaveAutomata.Governance.LawProposal
  alias SentientwaveAutomata.Governance.LawVote
  alias SentientwaveAutomata.Governance.Room
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.DirectoryUser
  require Logger

  @non_retryable_errors [
    :created_by_required,
    :eligible_roles_required,
    :ineligible_voter,
    :law_required,
    :missing_reference,
    :missing_sender,
    :not_authorized,
    :not_found,
    :not_open,
    :proposal_closed,
    :unknown_governance_actor
  ]

  @impl true
  def execute(
        _context,
        [%{"step" => "open_proposal", "workflow_id" => workflow_id, "command" => command}]
      ) do
    actor = resolve_actor!(command)

    if allowed_to_open?(actor) do
      attrs = proposal_attrs(command, actor, workflow_id)
      proposal = unwrap_result!(Governance.open_law_proposal(attrs), "open governance proposal")
      :ok = announce_proposal_opened(proposal, actor)
      [serialize_proposal(proposal)]
    else
      fail_non_retryable(
        "governance.proposal.not_authorized",
        "not authorized to open governance proposal"
      )
    end
  end

  def execute(_context, [%{"step" => "load_proposal", "proposal_id" => proposal_id}]) do
    case Governance.get_proposal(proposal_id) do
      %LawProposal{} = proposal ->
        [serialize_proposal(proposal)]

      nil ->
        fail_non_retryable(
          "governance.proposal.not_found",
          "governance proposal not found: #{proposal_id}"
        )
    end
  end

  def execute(
        _context,
        [%{"step" => "record_vote", "proposal_id" => proposal_id, "command" => command}]
      ) do
    proposal = get_proposal!(proposal_id)
    actor = resolve_actor!(command)

    vote =
      unwrap_result!(
        Governance.cast_vote(proposal.id, actor.id, vote_attrs(command)),
        "cast governance vote"
      )

    :ok = announce_vote_cast(proposal, vote, actor)
    [serialize_vote(vote)]
  end

  def execute(_context, [%{"step" => "resolve_proposal", "proposal_id" => proposal_id}]) do
    proposal = get_proposal!(proposal_id)

    resolved =
      unwrap_result!(Governance.resolve_proposal(proposal), "resolve governance proposal")

    _snapshot = maybe_apply_approved_proposal(resolved)
    latest = get_proposal!(proposal_id)
    :ok = announce_resolution(latest)
    [serialize_proposal(latest)]
  end

  def execute(_context, [payload]) do
    fail_non_retryable(
      "governance.proposal.unsupported_step",
      "unsupported governance proposal activity step: #{inspect(payload)}"
    )
  end

  defp maybe_apply_approved_proposal(%LawProposal{status: :approved} = proposal) do
    case Governance.apply_approved_proposal(proposal) do
      {:ok, snapshot} -> snapshot
      {:error, :not_approved} -> nil
      {:error, reason} -> raise "failed to apply approved proposal: #{inspect(reason)}"
    end
  end

  defp maybe_apply_approved_proposal(_proposal), do: nil

  defp proposal_attrs(command, %DirectoryUser{} = actor, workflow_id) do
    proposal_payload = fetch_map(command, "proposal")
    target_ref = fetch_value(command, "target_ref")
    role_ids = resolve_role_ids(fetch_list(command, "eligible_role_ids"))

    %{
      "workflow_id" => workflow_id,
      "proposal_type" => normalize_proposal_type(fetch_value(command, "proposal_type")),
      "law_id" => resolve_target_law_id(target_ref),
      "proposed_slug" => fetch_value(proposal_payload, "slug"),
      "proposed_name" => fetch_value(proposal_payload, "name"),
      "proposed_markdown_body" => fetch_value(proposal_payload, "markdown_body"),
      "proposed_law_kind" => fetch_value(proposal_payload, "law_kind"),
      "rule_config" => fetch_map(proposal_payload, "rule_config"),
      "reason" => fetch_value(proposal_payload, "reason") || fetch_value(command, "reason"),
      "voting_scope" => if(role_ids == [], do: "all_members", else: "role_subset"),
      "eligible_role_ids" => role_ids,
      "room_id" => fetch_value(command, "room_id"),
      "proposal_message_id" => fetch_value(command, "message_id"),
      "raw_event" => fetch_map(command, "raw_event"),
      "metadata" =>
        Map.merge(fetch_map(command, "metadata"), %{
          "source" => "matrix_governance",
          "sender_mxid" => fetch_value(command, "sender_mxid")
        }),
      "created_by_id" => actor.id
    }
  end

  defp vote_attrs(command) do
    %{
      "choice" => normalize_vote_choice(fetch_value(command, "choice")),
      "room_id" => fetch_value(command, "room_id"),
      "message_id" => fetch_value(command, "message_id"),
      "raw_event" => fetch_map(command, "raw_event"),
      "metadata" =>
        Map.merge(fetch_map(command, "metadata"), %{
          "source" => "matrix_governance",
          "sender_mxid" => fetch_value(command, "sender_mxid")
        }),
      "cast_at" => DateTime.utc_now()
    }
  end

  defp resolve_target_law_id(nil), do: nil
  defp resolve_target_law_id(""), do: nil

  defp resolve_target_law_id(target_ref) when is_binary(target_ref) do
    trimmed = String.trim(target_ref)

    cond do
      trimmed == "" ->
        nil

      law = Governance.get_law(trimmed) ->
        law.id

      law = Governance.get_law_by_slug(trimmed) ->
        law.id

      proposal = Governance.get_proposal_by_reference(trimmed) ->
        proposal.law_id

      true ->
        nil
    end
  end

  defp resolve_role_ids(role_refs) when is_list(role_refs) do
    role_refs
    |> Enum.map(fn ref ->
      cond do
        role = Governance.get_role(to_string(ref)) ->
          role.id

        role = Governance.get_role_by_slug(to_string(ref)) ->
          role.id

        true ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve_actor!(command) do
    sender_mxid = fetch_value(command, "sender_mxid")

    if is_binary(sender_mxid) and String.trim(sender_mxid) != "" do
      localpart =
        sender_mxid |> String.trim_leading("@") |> String.split(":", parts: 2) |> List.first()

      case Directory.get_user_record(localpart) do
        %DirectoryUser{} = actor ->
          actor

        nil ->
          fail_non_retryable("governance.proposal.unknown_actor", "unknown governance actor")

        {:error, reason} ->
          raise "failed to resolve governance actor: #{inspect(reason)}"

        _ ->
          fail_non_retryable("governance.proposal.unknown_actor", "unknown governance actor")
      end
    else
      fail_non_retryable("governance.proposal.missing_sender", "missing governance sender")
    end
  end

  defp allowed_to_open?(%DirectoryUser{admin: true}), do: true
  defp allowed_to_open?(%DirectoryUser{kind: :person}), do: true
  defp allowed_to_open?(_actor), do: false

  defp announce_proposal_opened(%LawProposal{} = proposal, %DirectoryUser{} = actor) do
    message =
      "Opened proposal #{proposal.reference} by #{actor.display_name || actor.localpart}. " <>
        proposal_summary(proposal)

    post_governance_message(proposal.room_id, message)
  end

  defp announce_vote_cast(%LawProposal{} = proposal, %LawVote{} = vote, %DirectoryUser{} = actor) do
    message =
      "Recorded #{vote.choice} vote for #{proposal.reference} from #{actor.display_name || actor.localpart}."

    post_governance_message(proposal.room_id, message)
  end

  defp announce_resolution(%LawProposal{} = proposal) do
    results = Governance.proposal_results(proposal)

    message =
      "Resolved proposal #{proposal.reference} as #{proposal.status}. " <>
        "Approve #{results.approve_count}, reject #{results.reject_count}, abstain #{results.abstain_count}."

    post_governance_message(proposal.room_id, message)
  end

  defp post_governance_message(room_id, message) do
    room_id = room_id || Room.room_id()

    case matrix_adapter().post_message(room_id, message, %{"kind" => "governance_update"}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "governance_update_post_failed room_id=#{inspect(room_id)} reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp serialize_proposal(%LawProposal{} = proposal) do
    %{
      "id" => proposal.id,
      "reference" => proposal.reference,
      "status" => Atom.to_string(proposal.status),
      "workflow_id" => proposal.workflow_id,
      "proposal_type" => Atom.to_string(proposal.proposal_type),
      "closes_at" => proposal.closes_at && DateTime.to_iso8601(proposal.closes_at),
      "wait_ms" => wait_ms(proposal.closes_at)
    }
  end

  defp serialize_vote(%LawVote{} = vote) do
    %{
      "id" => vote.id,
      "proposal_id" => vote.proposal_id,
      "voter_id" => vote.voter_id,
      "choice" => Atom.to_string(vote.choice)
    }
  end

  defp proposal_summary(%LawProposal{} = proposal) do
    law_name =
      proposal.proposed_name ||
        proposal.proposed_slug ||
        proposal.reference

    "#{proposal.proposal_type} #{law_name}"
  end

  defp wait_ms(nil), do: 0

  defp wait_ms(%DateTime{} = closes_at) do
    closes_at
    |> DateTime.diff(DateTime.utc_now(), :millisecond)
    |> max(0)
  end

  defp normalize_proposal_type(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_proposal_type(value) when is_binary(value), do: String.trim(value)
  defp normalize_proposal_type(_value), do: "create"

  defp normalize_vote_choice(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_vote_choice(value) when is_binary(value), do: String.trim(value)
  defp normalize_vote_choice(_value), do: "reject"

  defp fetch_value(map, key) when is_map(map) do
    atom_key =
      case key do
        "proposal" -> :proposal
        "eligible_role_ids" -> :eligible_role_ids
        "target_ref" -> :target_ref
        "room_id" -> :room_id
        "message_id" -> :message_id
        "sender_mxid" -> :sender_mxid
        "raw_event" -> :raw_event
        "metadata" -> :metadata
        "proposal_type" -> :proposal_type
        "choice" -> :choice
        "reason" -> :reason
        "rule_config" -> :rule_config
        "slug" -> :slug
        "name" -> :name
        "markdown_body" -> :markdown_body
        "law_kind" -> :law_kind
        _ -> nil
      end

    Map.get(map, key) || (atom_key && Map.get(map, atom_key))
  end

  defp fetch_map(map, key) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp fetch_list(map, key) do
    case fetch_value(map, key) do
      value when is_list(value) -> value
      value when is_binary(value) -> String.split(value, ",", trim: true)
      _ -> []
    end
  end

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp get_proposal!(proposal_id) do
    case Governance.get_proposal(proposal_id) do
      %LawProposal{} = proposal ->
        proposal

      nil ->
        fail_non_retryable(
          "governance.proposal.not_found",
          "governance proposal not found: #{proposal_id}"
        )
    end
  end

  defp unwrap_result!({:ok, result}, _action), do: result

  defp unwrap_result!({:error, reason}, action) when reason in @non_retryable_errors do
    fail_non_retryable("governance.proposal.#{reason}", "#{action} failed: #{inspect(reason)}")
  end

  defp unwrap_result!({:error, reason}, action) do
    raise "#{action} failed: #{inspect(reason)}"
  end

  defp unwrap_result!(result, _action), do: result

  defp fail_non_retryable(type, message) do
    fail(message: message, type: type, non_retryable: true)
  end
end
