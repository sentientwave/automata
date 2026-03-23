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

  defp test_pid do
    Process.get(:matrix_adapter_test_pid, self())
  end
end
