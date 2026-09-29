defmodule SentientwaveAutomata.TestSupport.MatrixAdapterStub do
  @behaviour SentientwaveAutomata.Adapters.Matrix.Behaviour

  def post_message(room_id, message, metadata) do
    send(test_pid(), {:matrix_post_message, room_id, message, metadata})
    Process.get(:matrix_post_message_response, :ok)
  end

  def set_typing(room_id, typing, timeout_ms, metadata) do
    send(test_pid(), {:matrix_set_typing, room_id, typing, timeout_ms, metadata})
    :ok
  end

  def ingest_event(event) do
    send(test_pid(), {:matrix_ingest_event, event})
    :ok
  end

  def post_message_as(room_id, message, credentials) do
    post_message_as(room_id, message, credentials, %{})
  end

  def post_message_as(room_id, message, credentials, metadata) do
    send(test_pid(), {:matrix_post_message_as, room_id, message, credentials, metadata})
    Process.get(:matrix_post_message_response, :ok)
  end

  def set_typing_as(room_id, typing, timeout_ms, credentials, metadata) do
    send(test_pid(), {:matrix_set_typing_as, room_id, typing, timeout_ms, credentials, metadata})
    :ok
  end

  def resolve_direct_room(_credentials, target_localpart) do
    send(test_pid(), {:matrix_resolve_direct_room, target_localpart})
    {:ok, Process.get(:matrix_direct_room, "!dm-room:localhost")}
  end

  def reader_localpart, do: "reader"

  defp test_pid do
    Process.get(:matrix_adapter_test_pid, self())
  end
end
