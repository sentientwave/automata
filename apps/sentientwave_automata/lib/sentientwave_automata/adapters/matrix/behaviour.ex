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
end
