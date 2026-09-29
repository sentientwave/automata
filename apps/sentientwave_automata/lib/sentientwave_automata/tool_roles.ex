defmodule SentientwaveAutomata.ToolRoles do
  @moduledoc """
  Role-based tool availability: tools can be mapped to org roles so that
  only agents holding those roles get the tool in their function-calling
  planner. Per-agent tool permission rows still override the role mapping.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Repo
  alias SentientwaveAutomata.ToolRoles.ToolRoleGrant

  @roles ~w(all executive department_head team_lead staff)

  @doc "The known org roles a tool can be mapped to."
  def roles, do: @roles

  @doc "Lists role grants, optionally filtered by tool."
  def list_grants(opts \\ []) do
    ToolRoleGrant
    |> maybe_filter_tool(Keyword.get(opts, :tool_name))
    |> order_by([g], asc: g.tool_name, asc: g.role)
    |> Repo.all()
  end

  @doc "Roles granted for a tool."
  def roles_for_tool(tool_name) do
    from(g in ToolRoleGrant, where: g.tool_name == ^tool_name, select: g.role)
    |> Repo.all()
  end

  @doc "Tool names that carry at least one role grant."
  def role_mapped_tools do
    from(g in ToolRoleGrant, select: g.tool_name, distinct: true)
    |> Repo.all()
  end

  @doc "Replaces the role grants for a tool (atomically)."
  def replace_grants(tool_name, roles) when is_list(roles) do
    Repo.transaction(fn ->
      Repo.delete_all(from(g in ToolRoleGrant, where: g.tool_name == ^tool_name))

      Enum.each(roles, fn role ->
        if role in @roles do
          %ToolRoleGrant{}
          |> ToolRoleGrant.changeset(%{tool_name: tool_name, role: role})
          |> Repo.insert!()
        end
      end)
    end)

    :ok
  end

  @doc """
  Whether the agent may use the tool, considering role grants and explicit
  per-agent permission overrides (an explicit row always wins; with no row,
  a role-mapped tool requires a matching role, and unmapped tools fall back
  to the executor's default policy).
  """
  def allowed_for_agent?(agent, tool_name) do
    case SentientwaveAutomata.Agents.get_tool_permission(agent.id, tool_name, "default") do
      %{allowed: allowed} ->
        allowed

      nil ->
        case roles_for_tool(tool_name) do
          [] -> :default
          roles -> "all" in roles or SentientwaveAutomata.OrgChart.role_for(agent) in roles
        end
    end
  end

  @doc "Role held by an agent, as a string."
  def role_for(agent), do: SentientwaveAutomata.OrgChart.role_for(agent)

  defp maybe_filter_tool(query, nil), do: query
  defp maybe_filter_tool(query, ""), do: query
  defp maybe_filter_tool(query, tool_name), do: where(query, [g], g.tool_name == ^tool_name)
end
