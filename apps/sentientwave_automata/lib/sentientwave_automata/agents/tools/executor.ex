defmodule SentientwaveAutomata.Agents.Tools.Executor do
  @moduledoc """
  Resolves configured tools, performs permission checks, and executes tool calls.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Tools.Registry
  alias SentientwaveAutomata.Settings

  @type available_tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          base_url: String.t(),
          api_token: String.t()
        }

  @spec available_tools(binary() | nil) :: [available_tool()]
  def available_tools(agent_id) do
    Settings.list_enabled_tool_configs()
    |> Enum.reduce([], fn config, acc ->
      with true <- tool_callable?(config),
           true <- allowed_for_agent?(agent_id, config.tool_name),
           {:ok, module} <- Registry.module_for(config.tool_name) do
        [
          %{
            name: module.name(),
            description: module.description(),
            parameters: module.parameters(),
            base_url: config.base_url || "",
            api_token: config.api_token || ""
          }
          | acc
        ]
      else
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end

  @spec execute(String.t(), map(), [available_tool()]) :: {:ok, map()} | {:error, term()}
  def execute(tool_name, args, available) when is_binary(tool_name) and is_map(args) do
    case Enum.find(available, fn tool -> tool.name == tool_name end) do
      nil ->
        {:error, :tool_not_available}

      tool ->
        with {:ok, module} <- Registry.module_for(tool_name),
             {:ok, result} <-
               module.call(args, base_url: tool.base_url, api_token: tool.api_token) do
          {:ok, result}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp allowed_for_agent?(nil, tool_name), do: not privileged_tool?(tool_name)
  defp allowed_for_agent?("", tool_name), do: not privileged_tool?(tool_name)

  defp allowed_for_agent?(agent_id, tool_name) do
    if privileged_tool?(tool_name) do
      case Agents.get_tool_permission(agent_id, tool_name, "default") do
        nil -> false
        permission -> permission.allowed
      end
    else
      Agents.allowed_tool?(agent_id, tool_name, "default")
    end
  end

  defp tool_callable?(_), do: true

  defp privileged_tool?(tool_name), do: tool_name in ["system_directory_admin", "run_shell"]
end
