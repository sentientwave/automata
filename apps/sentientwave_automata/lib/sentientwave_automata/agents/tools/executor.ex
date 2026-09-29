defmodule SentientwaveAutomata.Agents.Tools.Executor do
  @moduledoc """
  Resolves configured tools, performs permission checks, and executes tool calls.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.AgentProfile
  alias SentientwaveAutomata.Agents.Tools.Registry
  alias SentientwaveAutomata.Settings
  alias SentientwaveAutomata.ToolRoles

  @type available_tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map(),
          base_url: String.t(),
          api_token: String.t()
        }

  # Tools available to every agent without a stored tool config row.
  @builtin_tools ["send_matrix_message", "search_org_chart"]

  @spec available_tools(binary() | nil) :: [available_tool()]
  def available_tools(agent_id) do
    configured =
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

    builtins =
      Enum.reduce(@builtin_tools, [], fn tool_name, acc ->
        with true <- allowed_for_agent?(agent_id, tool_name),
             {:ok, module} <- Registry.module_for(tool_name) do
          [
            %{
              name: module.name(),
              description: module.description(),
              parameters: module.parameters(),
              base_url: "",
              api_token: ""
            }
            | acc
          ]
        else
          _ -> acc
        end
      end)

    (configured ++ builtins)
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.name)
  end

  @spec execute(String.t(), map(), [available_tool()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute(tool_name, args, available, opts \\ [])
      when is_binary(tool_name) and is_map(args) do
    case Enum.find(available, fn tool -> tool.name == tool_name end) do
      nil ->
        {:error, :tool_not_available}

      tool ->
        with {:ok, module} <- Registry.module_for(tool_name),
             {:ok, result} <-
               module.call(args,
                 base_url: tool.base_url,
                 api_token: tool.api_token,
                 agent_id: Keyword.get(opts, :agent_id)
               ) do
          {:ok, result}
        else
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp allowed_for_agent?(nil, tool_name), do: default_allowed?(tool_name)
  defp allowed_for_agent?("", tool_name), do: default_allowed?(tool_name)

  defp allowed_for_agent?(agent_id, tool_name) do
    case Agents.get_agent(agent_id) do
      %AgentProfile{} = agent ->
        if privileged_tool?(tool_name) do
          case Agents.get_tool_permission(agent_id, tool_name, "default") do
            nil -> false
            permission -> permission.allowed
          end
        else
          case ToolRoles.allowed_for_agent?(agent, tool_name) do
            :default -> Agents.allowed_tool?(agent_id, tool_name, "default")
            allowed -> allowed
          end
        end

      _ ->
        default_allowed?(tool_name)
    end
  end

  defp default_allowed?(tool_name), do: not privileged_tool?(tool_name)

  defp tool_callable?(_), do: true

  defp privileged_tool?(tool_name),
    do: tool_name in ["system_directory_admin", "run_shell", "hire_agent", "fire_agent"]
end
