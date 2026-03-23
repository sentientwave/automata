defmodule SentientwaveAutomata.Governance.ProposalWorkflow do
  @moduledoc """
  Temporal-owned governance proposal lifecycle workflow.
  """

  use TemporalSdk.Workflow

  alias SentientwaveAutomata.Temporal

  @activity SentientwaveAutomata.Governance.ProposalActivities
  @vote_signal "vote"
  @resolve_signal "resolve"

  @impl true
  def execute(_context, [input]) do
    proposal =
      case Map.get(input, "mode", "open") do
        "resume" ->
          activity("load_proposal", %{"proposal_id" => Map.get(input, "proposal_id")})

        _ ->
          activity("open_proposal", %{
            "workflow_id" => Map.get(input, "workflow_id"),
            "command" => Map.get(input, "command", %{})
          })
      end

    wait_for_resolution(proposal)
  end

  defp wait_for_resolution(%{"id" => proposal_id, "status" => "open"} = proposal) do
    timer = start_timer(Map.get(proposal, "wait_ms", 0))

    case wait_one([timer, {:signal_request, @vote_signal}, {:signal_request, @resolve_signal}]) do
      [%{state: :fired}, :noevent, :noevent] ->
        activity("resolve_proposal", %{"proposal_id" => proposal_id})

      [:noevent, vote_signal, :noevent] ->
        _ = admit_signal(@vote_signal, wait: true)

        _ =
          activity("record_vote", %{
            "proposal_id" => proposal_id,
            "command" => signal_payload(vote_signal)
          })

        proposal = activity("load_proposal", %{"proposal_id" => proposal_id})
        wait_for_resolution(proposal)

      [:noevent, :noevent, _resolve_signal] ->
        _ = admit_signal(@resolve_signal, wait: true)
        activity("resolve_proposal", %{"proposal_id" => proposal_id})
    end
  end

  defp wait_for_resolution(proposal), do: proposal

  defp activity(step, payload) do
    [%{result: result}] =
      wait_all([
        start_activity(
          @activity,
          [Temporal.activity_payload(step, payload)],
          task_queue: Temporal.activity_task_queue(),
          start_to_close_timeout: {15, :minute}
        )
      ])

    unwrap_activity_result(result)
  end

  defp signal_payload(%{input: [payload]}), do: payload
  defp signal_payload(%{input: payload}) when is_map(payload), do: payload
  defp signal_payload(_signal), do: %{}

  defp unwrap_activity_result([value]), do: value
  defp unwrap_activity_result({:ok, value}), do: value
  defp unwrap_activity_result(value), do: value
end
