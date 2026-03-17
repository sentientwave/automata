defmodule SentientwaveAutomata.Agents.LLMProvider do
  @moduledoc false

  @callback complete([map()], keyword()) :: {:ok, String.t()} | {:error, term()}
end
