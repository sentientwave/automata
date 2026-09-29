defmodule SentientwaveAutomata.Agents.Tools.Registry do
  @moduledoc false

  @tools %{
    "brave_search" => SentientwaveAutomata.Agents.Tools.BraveSearch,
    "system_directory_admin" => SentientwaveAutomata.Agents.Tools.SystemDirectoryAdmin,
    "run_shell" => SentientwaveAutomata.Agents.Tools.RunShell,
    "send_matrix_message" => SentientwaveAutomata.Agents.Tools.SendMatrixMessage,
    "search_org_chart" => SentientwaveAutomata.Agents.Tools.OrgChart,
    "hire_agent" => SentientwaveAutomata.Agents.Tools.HireAgent,
    "fire_agent" => SentientwaveAutomata.Agents.Tools.FireAgent,
    "create_matrix_room" => SentientwaveAutomata.Agents.Tools.CreateMatrixRoom,
    "delete_matrix_room" => SentientwaveAutomata.Agents.Tools.DeleteMatrixRoom,
    "create_department" => SentientwaveAutomata.Agents.Tools.CreateDepartment,
    "destroy_department" => SentientwaveAutomata.Agents.Tools.DestroyDepartment,
    "create_team" => SentientwaveAutomata.Agents.Tools.CreateTeam,
    "set_reports_to" => SentientwaveAutomata.Agents.Tools.SetReportsTo,
    "assign_org_unit" => SentientwaveAutomata.Agents.Tools.AssignOrgUnit,
    "org_job_status" => SentientwaveAutomata.Agents.Tools.OrgJobStatus
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
