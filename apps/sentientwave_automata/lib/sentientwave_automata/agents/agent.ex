defmodule SentientwaveAutomata.Agents.Agent do
  @moduledoc """
  Behaviour for cooperative agent roles.
  """

  @callback role() :: atom()
  @callback execute(map()) :: {:ok, map()} | {:error, term()}
end
