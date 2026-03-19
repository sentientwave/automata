defmodule SentientwaveAutomata.Adapters.Matrix.Local do
  @moduledoc """
  Local adapter used in development and tests.
  """

  @behaviour SentientwaveAutomata.Adapters.Matrix.Behaviour
  require Logger

  alias SentientwaveAutomata.Agents.MentionDispatcher

  @impl true
  def post_message(room_id, message, metadata) do
    Logger.info("matrix_local room=#{room_id} message=#{message} meta=#{inspect(metadata)}")
    :ok
  end

  @impl true
  def set_typing(room_id, typing, timeout_ms, metadata) do
    Logger.info(
      "matrix_local_typing room=#{room_id} typing=#{typing} timeout_ms=#{timeout_ms} meta=#{inspect(metadata)}"
    )

    :ok
  end

  @impl true
  def ingest_event(%{"type" => "m.room.message", "content" => %{"body" => body}} = event) do
    MentionDispatcher.dispatch(%{
      room_id: Map.get(event, "room_id", ""),
      sender_mxid: Map.get(event, "sender", ""),
      message_id:
        Map.get(event, "event_id", Integer.to_string(System.unique_integer([:positive]))),
      body: body,
      raw_event: event,
      metadata: %{"source" => "matrix_local", "conversation_scope" => "room"}
    })

    :ok
  end

  def ingest_event(_event), do: :ok
end
