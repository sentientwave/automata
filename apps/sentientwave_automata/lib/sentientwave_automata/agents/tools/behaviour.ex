defmodule SentientwaveAutomata.Agents.Tools.Behaviour do
  @moduledoc false

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback call(map(), keyword()) :: {:ok, map()} | {:error, term()}
end
