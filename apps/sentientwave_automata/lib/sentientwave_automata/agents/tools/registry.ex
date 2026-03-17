defmodule SentientwaveAutomata.Agents.Tools.Registry do
  @moduledoc false

  @tools %{
    "brave_search" => SentientwaveAutomata.Agents.Tools.BraveSearch,
    "system_directory_admin" => SentientwaveAutomata.Agents.Tools.SystemDirectoryAdmin,
    "run_shell" => SentientwaveAutomata.Agents.Tools.RunShell
  }

  @spec module_for(String.t()) :: {:ok, module()} | {:error, :unsupported_tool}
  def module_for(tool_name) when is_binary(tool_name) do
    case Map.get(@tools, tool_name) do
      nil -> {:error, :unsupported_tool}
      mod -> {:ok, mod}
    end
  end

  @spec list_supported() :: [String.t()]
  def list_supported, do: Map.keys(@tools)
end
