defmodule SentientwaveAutomata.Governance.ProposalResolutionWorker do
  @moduledoc """
  Periodically resolves governance proposals whose voting window has closed.
  """

  use GenServer

  require Logger

  @default_interval_ms 30_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    Process.send_after(self(), :tick, 5_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    resolve_due_proposals()
    Process.send_after(self(), :tick, poll_interval_ms())
    {:noreply, state}
  end

  defp resolve_due_proposals do
    now = DateTime.utc_now()

    SentientwaveAutomata.Governance.list_proposals(status: :open)
    |> Enum.filter(fn proposal ->
      match?(%DateTime{}, proposal.closes_at) and DateTime.compare(proposal.closes_at, now) != :gt
    end)
    |> Enum.each(fn proposal ->
      case SentientwaveAutomata.Governance.Workflow.resolve_proposal(proposal.reference) do
        {:ok, _resolved} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "governance_proposal_resolution_failed proposal_id=#{proposal.id} reference=#{proposal.reference} reason=#{inspect(reason)}"
          )
      end
    end)
  end

  defp poll_interval_ms do
    System.get_env("GOVERNANCE_RESOLUTION_INTERVAL_MS", Integer.to_string(@default_interval_ms))
    |> String.to_integer()
  rescue
    _ -> @default_interval_ms
  end
end
