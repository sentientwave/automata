defmodule SentientwaveAutomata.Matrix.MentionPoller do
  @moduledoc """
  Polls Matrix `/sync` and forwards room message events to Matrix adapter ingress.
  """

  use GenServer

  require Logger

  @default_interval_ms 2_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(_state) do
    if enabled?() do
      since = initial_since_token()
      Process.send_after(self(), :poll, 1_000)
      {:ok, %{since: since}}
    else
      Logger.info("matrix_mention_poller disabled")
      {:ok, %{since: nil, disabled: true}}
    end
  end

  @impl true
  def handle_info(:poll, %{disabled: true} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    new_state =
      case SentientwaveAutomata.Adapters.Matrix.Synapse.sync(state.since) do
        {:ok, payload} ->
          process_invites(payload)
          process_sync(payload)
          %{state | since: Map.get(payload, "next_batch", state.since)}

        {:error, reason} ->
          Logger.warning("matrix_mention_poller sync_error=#{inspect(reason)}")
          state
      end

    Process.send_after(self(), :poll, poll_interval_ms())
    {:noreply, new_state}
  end

  defp process_sync(%{"rooms" => %{"join" => joined}}) when is_map(joined) do
    Enum.each(joined, fn {room_id, room_payload} ->
      events = get_in(room_payload, ["timeline", "events"]) || []

      Enum.each(events, fn event ->
        if should_process_event?(event) do
          event = Map.put(event, "room_id", room_id)
          _ = matrix_adapter().ingest_event(event)
        end
      end)
    end)
  end

  defp process_sync(_), do: :ok

  defp process_invites(%{"rooms" => %{"invite" => invited}}) when is_map(invited) do
    Enum.each(Map.keys(invited), fn room_id ->
      case SentientwaveAutomata.Adapters.Matrix.Synapse.accept_invite(room_id) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("matrix_invite_accept_failed room=#{room_id} reason=#{inspect(reason)}")
      end
    end)
  end

  defp process_invites(_), do: :ok

  defp should_process_event?(%{"type" => "m.room.message", "sender" => sender})
       when is_binary(sender) do
    sender != bot_mxid()
  end

  defp should_process_event?(_), do: false

  defp matrix_adapter do
    Application.get_env(
      :sentientwave_automata,
      :matrix_adapter,
      SentientwaveAutomata.Adapters.Matrix.Local
    )
  end

  defp poll_interval_ms do
    System.get_env("MATRIX_SYNC_INTERVAL_MS", Integer.to_string(@default_interval_ms))
    |> String.to_integer()
  rescue
    _ -> @default_interval_ms
  end

  defp enabled? do
    System.get_env("MATRIX_POLL_ENABLED", "true") in ["1", "true", "TRUE", "yes", "YES"]
  end

  defp initial_since_token do
    case System.get_env("MATRIX_SYNC_START_FROM_NOW", "true") do
      value when value in ["1", "true", "TRUE", "yes", "YES"] ->
        case SentientwaveAutomata.Adapters.Matrix.Synapse.sync(nil) do
          {:ok, %{"next_batch" => token}} when is_binary(token) and token != "" ->
            token

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp bot_mxid do
    "@#{System.get_env("MATRIX_AGENT_USER", "automata")}:#{System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")}"
  end
end
