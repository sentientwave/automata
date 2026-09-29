defmodule SentientwaveAutomata.Governance.Workflow do
  @moduledoc """
  Control-plane boundary for Temporal-owned governance proposal workflows.
  """

  require Logger

  alias SentientwaveAutomata.Governance
  alias SentientwaveAutomata.Governance.LawProposal
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.DirectoryUser
  alias SentientwaveAutomata.Repo
  alias SentientwaveAutomata.Temporal

  @poll_interval_ms 100
  @poll_timeout_ms 3_000
  @vote_signal "vote"
  @resolve_signal "resolve"

  @spec handle_command(map()) :: {:ok, map()} | {:error, term()} | :ignore
  def handle_command(%{proposal_type: _} = command), do: open_proposal(command)
  def handle_command(%{choice: _} = command), do: cast_vote(command)
  def handle_command(_command), do: :ignore

  @spec open_proposal(map()) :: {:ok, LawProposal.t()} | {:error, term()}
  def open_proposal(command) when is_map(command) do
    with {:ok, actor} <- resolve_actor(command),
         true <- allowed_to_open?(actor) || {:error, :not_authorized} do
      # Redelivered Matrix events (sync stream retries) must not create a
      # second proposal for the same message: the first delivery already
      # stored its proposal_message_id.
      case existing_proposal_for_message(command) do
        %LawProposal{} = existing -> {:ok, existing}
        nil -> start_open_proposal(command)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_open_proposal(command) do
    with workflow_id <- Temporal.generated_workflow_id("governance_proposal"),
         {:ok, _temporal} <-
           temporal_adapter().start_workflow(
             "governance_proposal_workflow",
             %{
               "mode" => "open",
               "workflow_id" => workflow_id,
               "command" => normalize_command(command)
             },
             workflow_id: workflow_id
           ),
         {:ok, proposal} <- await_proposal(workflow_id, @poll_timeout_ms) do
      {:ok, proposal}
    end
  end

  defp existing_proposal_for_message(command) do
    message_id = fetch_value(command, "message_id")

    if is_binary(message_id) and String.trim(message_id) != "" do
      Repo.get_by(LawProposal, proposal_message_id: String.trim(message_id))
    else
      nil
    end
  end

  @spec cast_vote(map()) :: {:ok, Governance.LawVote.t()} | {:error, term()}
  def cast_vote(command) when is_map(command) do
    with {:ok, actor} <- resolve_actor(command),
         {:ok, proposal} <- resolve_open_proposal(command),
         {:ok, workflow_id} <- ensure_proposal_workflow(proposal),
         # G3: snapshot any PRIOR vote so await_vote can tell "old vote row"
         # apart from THIS signal being processed.
         baseline <- prior_vote_snapshot(proposal.id, actor.id),
         :ok <-
           temporal_adapter().signal_workflow(
             workflow_id,
             @vote_signal,
             normalize_command(Map.put(command, :actor_id, actor.id))
           ),
         {:ok, vote} <- await_vote(proposal.id, actor.id, baseline, @poll_timeout_ms) do
      {:ok, vote}
    end
  end

  @spec resolve_proposal(map() | binary()) :: {:ok, LawProposal.t()} | {:error, term()}
  def resolve_proposal(reference) when is_binary(reference) do
    resolve_proposal(%{"reference" => reference})
  end

  def resolve_proposal(%{} = attrs) do
    with {:ok, _actor} <- authorize_resolver(attrs),
         {:ok, proposal} <- resolve_proposal_record(attrs),
         {:ok, workflow_id} <- ensure_proposal_workflow(proposal),
         :ok <-
           temporal_adapter().signal_workflow(
             workflow_id,
             @resolve_signal,
             normalize_command(attrs)
           ),
         {:ok, resolved} <- await_resolved_proposal(proposal.id, @poll_timeout_ms) do
      {:ok, resolved}
    end
  end

  @spec current_constitution_snapshot() :: Governance.ConstitutionSnapshot.t() | nil
  def current_constitution_snapshot, do: Governance.current_constitution_snapshot()

  @spec proposal_results(Governance.LawProposal.t() | binary()) :: map() | {:error, term()}
  def proposal_results(%LawProposal{} = proposal), do: Governance.proposal_results(proposal)

  def proposal_results(reference) when is_binary(reference) do
    case Governance.get_proposal_by_reference(reference) do
      %LawProposal{} = proposal -> Governance.proposal_results(proposal)
      nil -> {:error, :not_found}
    end
  end

  @spec reconcile_open_proposals() :: :ok
  def reconcile_open_proposals do
    Governance.list_proposals(status: :open)
    |> Enum.each(fn proposal ->
      case ensure_proposal_workflow(proposal) do
        {:ok, _workflow_id} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "governance_temporal_reconcile_failed proposal_id=#{proposal.id} reference=#{proposal.reference} reason=#{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  # G6: resolving a proposal early is a privileged action - it must not be
  # callable by an unauthenticated caller (open/cast_vote already require an
  # authorized actor).
  defp authorize_resolver(attrs) do
    with {:ok, actor} <- resolve_actor(attrs),
         true <- allowed_to_open?(actor) || {:error, :not_authorized} do
      {:ok, actor}
    end
  end

  defp ensure_proposal_workflow(%LawProposal{} = proposal) do
    workflow_id =
      proposal.workflow_id ||
        Temporal.child_workflow_id("governance_proposal", proposal.id)

    case proposal.workflow_id do
      value when is_binary(value) and value != "" ->
        case temporal_adapter().query_workflow(value) do
          {:ok, _status} ->
            {:ok, value}

          {:error, reason} ->
            if workflow_missing?(reason) do
              start_resume_workflow(proposal, workflow_id)
            else
              # Transient query failure (timeout, unavailable): restarting
              # would collide with the LIVE workflow (duplicate workflow id),
              # breaking votes/resolve until the query succeeds. Surface it.
              {:error, {:proposal_workflow_query_failed, reason}}
            end
        end

      _ ->
        start_resume_workflow(proposal, workflow_id)
    end
  end

  defp workflow_missing?(reason) do
    reason |> inspect() |> String.downcase() |> String.contains?("not_found")
  end

  defp start_resume_workflow(%LawProposal{} = proposal, workflow_id) do
    case temporal_adapter().start_workflow(
           "governance_proposal_workflow",
           %{
             "mode" => "resume",
             "workflow_id" => workflow_id,
             "proposal_id" => proposal.id
           },
           workflow_id: workflow_id
         ) do
      {:ok, _temporal} ->
        proposal
        |> Ecto.Changeset.change(%{workflow_id: workflow_id})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated.workflow_id}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp await_proposal(_workflow_id, remaining_ms) when remaining_ms <= 0,
    do: {:error, :proposal_not_persisted}

  defp await_proposal(workflow_id, remaining_ms) do
    case Repo.get_by(LawProposal, workflow_id: workflow_id) do
      %LawProposal{} = proposal ->
        {:ok, Governance.get_proposal(proposal)}

      nil ->
        Process.sleep(@poll_interval_ms)
        await_proposal(workflow_id, remaining_ms - @poll_interval_ms)
    end
  end

  defp prior_vote_snapshot(proposal_id, actor_id) do
    case Repo.get_by(Governance.LawVote, proposal_id: proposal_id, voter_id: actor_id) do
      %Governance.LawVote{} = vote -> {vote.choice, vote.updated_at}
      nil -> nil
    end
  end

  # No prior vote: the first row that appears IS this vote.
  defp await_vote(proposal_id, actor_id, nil, remaining_ms) do
    if remaining_ms <= 0 do
      {:error, :vote_not_persisted}
    else
      case Repo.get_by(Governance.LawVote, proposal_id: proposal_id, voter_id: actor_id) do
        %Governance.LawVote{} = vote ->
          {:ok, Repo.preload(vote, [:voter])}

        nil ->
          Process.sleep(@poll_interval_ms)
          await_vote(proposal_id, actor_id, nil, remaining_ms - @poll_interval_ms)
      end
    end
  end

  # G3: a pre-existing vote must not be reported as the result of THIS signal -
  # wait until the choice changes or the row is updated, otherwise failures
  # like :not_open/:ineligible_voter would be masked by a stale success.
  defp await_vote(_proposal_id, _actor_id, _baseline, remaining_ms)
       when remaining_ms <= 0 do
    {:error, :vote_not_recorded}
  end

  defp await_vote(proposal_id, actor_id, {prior_choice, prior_updated_at}, remaining_ms) do
    case Repo.get_by(Governance.LawVote, proposal_id: proposal_id, voter_id: actor_id) do
      %Governance.LawVote{} = vote ->
        if vote_changed?(vote, prior_choice, prior_updated_at) do
          {:ok, Repo.preload(vote, [:voter])}
        else
          Process.sleep(@poll_interval_ms)

          await_vote(
            proposal_id,
            actor_id,
            {prior_choice, prior_updated_at},
            remaining_ms - @poll_interval_ms
          )
        end

      nil ->
        Process.sleep(@poll_interval_ms)

        await_vote(
          proposal_id,
          actor_id,
          {prior_choice, prior_updated_at},
          remaining_ms - @poll_interval_ms
        )
    end
  end

  defp vote_changed?(%{choice: choice, updated_at: updated_at}, prior_choice, prior_ts) do
    choice != prior_choice or
      (updated_at != nil and prior_ts != nil and DateTime.compare(updated_at, prior_ts) == :gt)
  end

  defp await_resolved_proposal(_proposal_id, remaining_ms) when remaining_ms <= 0,
    do: {:error, :proposal_not_resolved}

  defp await_resolved_proposal(proposal_id, remaining_ms) do
    case Governance.get_proposal(proposal_id) do
      %LawProposal{status: :open} ->
        Process.sleep(@poll_interval_ms)
        await_resolved_proposal(proposal_id, remaining_ms - @poll_interval_ms)

      %LawProposal{} = proposal ->
        {:ok, proposal}

      nil ->
        {:error, :not_found}
    end
  end

  defp resolve_open_proposal(command) do
    with {:ok, proposal} <- resolve_proposal_record(command),
         true <- proposal.status == :open || {:error, :proposal_closed} do
      {:ok, proposal}
    end
  end

  defp resolve_proposal_record(attrs) when is_map(attrs) do
    cond do
      is_binary(fetch_value(attrs, "proposal_id")) ->
        case Governance.get_proposal(fetch_value(attrs, "proposal_id")) do
          %LawProposal{} = proposal -> {:ok, proposal}
          nil -> {:error, :not_found}
        end

      is_binary(fetch_value(attrs, "reference")) ->
        case Governance.get_proposal_by_reference(fetch_value(attrs, "reference")) do
          %LawProposal{} = proposal -> {:ok, proposal}
          nil -> {:error, :not_found}
        end

      true ->
        {:error, :missing_reference}
    end
  end

  defp resolve_actor(command) do
    sender_mxid = fetch_value(command, "sender_mxid")

    with true <-
           (is_binary(sender_mxid) and String.trim(sender_mxid) != "") ||
             {:error, :missing_sender},
         localpart <-
           sender_mxid |> String.trim_leading("@") |> String.split(":", parts: 2) |> List.first(),
         %DirectoryUser{} = actor <- Directory.get_user_record(localpart) do
      {:ok, actor}
    else
      nil -> {:error, :unknown_sender}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unknown_sender}
    end
  end

  defp allowed_to_open?(%DirectoryUser{admin: true}), do: true
  defp allowed_to_open?(%DirectoryUser{kind: :person}), do: true
  defp allowed_to_open?(_actor), do: false

  defp normalize_command(command) when is_map(command) do
    Enum.reduce(command, %{}, fn {key, value}, acc ->
      normalized_key =
        case key do
          atom when is_atom(atom) -> Atom.to_string(atom)
          binary when is_binary(binary) -> binary
        end

      Map.put(acc, normalized_key, normalize_value(value))
    end)
  end

  defp normalize_value(value) when is_map(value), do: normalize_command(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp fetch_value(map, key) do
    atom_key =
      case key do
        "proposal_id" -> :proposal_id
        "reference" -> :reference
        "sender_mxid" -> :sender_mxid
        _ -> nil
      end

    Map.get(map, key) || (atom_key && Map.get(map, atom_key))
  end

  defp temporal_adapter do
    Application.get_env(
      :sentientwave_automata,
      :temporal_adapter,
      SentientwaveAutomata.Adapters.Temporal.Runtime
    )
  end
end
