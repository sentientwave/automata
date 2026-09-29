defmodule SentientwaveAutomataTemporal.Telemetry do
  @moduledoc """
  Temporal SDK telemetry handler replacing the SDK default, which logs every
  `*exception*` event at `:error`.

  Long-poll gRPC streams make two error shapes benign noise:

  - `{:grpc_error, {:stream_error, {:closed, :normal}}}` — the Temporal server
    closes the poll stream (GOAWAY/RST with no response) when the poll
    deadline expires; the poller simply starts the next poll.
  - `{:grpc_error, :timeout}` — client-side deadline on a slow request.

  Both are downgraded (`:debug` / `:warning`) so genuinely unexpected SDK
  exceptions remain visible at `:error`.
  """

  require Logger

  @doc "Telemetry handler: `{event, measurements, metadata, config} -> any()`."
  def handle_log(event, measurements, metadata, _config) do
    Logger.log(level_for(event, metadata), format(event, measurements, metadata))
  end

  defp level_for(event, metadata) do
    case Map.get(metadata, :reason) do
      {:grpc_error, {:stream_error, {:closed, _}}} -> :debug
      {:grpc_error, :timeout} -> :warning
      _ -> default_level(event)
    end
  end

  # Mirror the SDK default handler: exception events log at :error.
  defp default_level(event) do
    if List.last(event) == :exception, do: :error, else: :notice
  end

  defp format(event, measurements, metadata) do
    measurements =
      case Map.get(measurements, :duration) do
        nil ->
          measurements

        duration ->
          Map.put(
            measurements,
            :duration,
            System.convert_time_unit(duration, :native, :millisecond)
          )
      end

    %{telemetry_event: event}
    |> Map.merge(measurements)
    |> Map.merge(metadata)
    |> inspect()
  end
end
