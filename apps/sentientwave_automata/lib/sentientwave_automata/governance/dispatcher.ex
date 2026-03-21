defmodule SentientwaveAutomata.Governance.Dispatcher do
  @moduledoc """
  Routes Matrix room messages into governance command handling when they occur
  in the dedicated governance room.
  """

  require Logger

  alias SentientwaveAutomata.Governance.CommandParser
  alias SentientwaveAutomata.Governance.Room
  alias SentientwaveAutomata.Governance.Workflow

  @spec dispatch(map()) :: :pass_through | {:governance, term()}
  def dispatch(%{"type" => "m.room.message"} = event) do
    room_id = event_room_id(event)
    sender = event_sender(event)

    cond do
      not Room.room?(room_id) ->
        :pass_through

      sender == Room.bot_mxid() ->
        {:governance, :ignored}

      true ->
        case CommandParser.parse(event) do
          {:proposal, command} ->
            {:governance, Workflow.open_proposal(command)}

          {:vote, command} ->
            {:governance, Workflow.cast_vote(command)}

          :ignore ->
            {:governance, :ignored}

          {:error, reason} ->
            Logger.warning(
              "governance_command_parse_failed room=#{room_id} sender=#{sender} reason=#{inspect(reason)}"
            )

            {:governance, {:error, reason}}
        end
    end
  end

  def dispatch(_event), do: :pass_through

  defp event_room_id(event) do
    Map.get(event, "room_id") ||
      Map.get(event, :room_id) ||
      ""
  end

  defp event_sender(event) do
    Map.get(event, "sender") ||
      Map.get(event, :sender_mxid) ||
      ""
  end
end
