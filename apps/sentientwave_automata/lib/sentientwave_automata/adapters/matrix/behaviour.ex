defmodule SentientwaveAutomata.Adapters.Matrix.Behaviour do
  @moduledoc """
  Boundary for Matrix messaging ingress/egress.
  """

  @callback post_message(room_id :: String.t(), message :: String.t(), metadata :: map()) ::
              :ok | {:error, term()}

  @callback set_typing(
              room_id :: String.t(),
              typing :: boolean(),
              timeout_ms :: non_neg_integer(),
              metadata :: map()
            ) :: :ok | {:error, term()}

  @callback ingest_event(event :: map()) :: :ok | {:error, term()}

  @callback post_message_as(
              room_id :: String.t(),
              message :: String.t(),
              credentials :: map(),
              metadata :: map()
            ) ::
              :ok | {:error, term()}

  @callback set_typing_as(
              room_id :: String.t(),
              typing :: boolean(),
              timeout_ms :: non_neg_integer(),
              credentials :: map(),
              metadata :: map()
            ) :: :ok | {:error, term()}

  @optional_callbacks post_message_as: 4, set_typing_as: 5
end
