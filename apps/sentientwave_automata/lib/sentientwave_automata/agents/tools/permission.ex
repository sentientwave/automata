defmodule SentientwaveAutomata.Agents.Tools.Permission do
  @moduledoc """
  Permission checks for local/MCP tools.
  """

  alias SentientwaveAutomata.Agents

  @spec allowed?(binary(), String.t(), String.t()) :: boolean()
  def allowed?(agent_id, tool_name, scope \\ "default") do
    Agents.allowed_tool?(agent_id, tool_name, scope)
  end

  @spec assert_allowed(binary(), String.t(), String.t()) :: :ok | {:error, :forbidden}
  def assert_allowed(agent_id, tool_name, scope \\ "default") do
    if allowed?(agent_id, tool_name, scope), do: :ok, else: {:error, :forbidden}
  end
end
