defmodule SentientwaveAutomata.ToolRolesTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Tools.Executor
  alias SentientwaveAutomata.OrgChart
  alias SentientwaveAutomata.ToolRoles

  setup do
    previous = System.get_env("AUTOMATA_ORG_EXECUTIVE_LOCALPARTS")
    System.put_env("AUTOMATA_ORG_EXECUTIVE_LOCALPARTS", "exec.agent")

    on_exit(fn ->
      if previous,
        do: System.put_env("AUTOMATA_ORG_EXECUTIVE_LOCALPARTS", previous),
        else: System.delete_env("AUTOMATA_ORG_EXECUTIVE_LOCALPARTS")
    end)

    :ok
  end

  defp insert_agent(lp, name, title, opts \\ %{}) do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: lp,
        kind: :agent,
        display_name: name,
        matrix_localpart: lp,
        status: :active,
        metadata:
          Map.merge(
            %{"title" => title, "department" => "Investments Department"},
            Map.get(opts, :metadata, %{})
          )
      })

    profile
  end

  test "computes org roles from titles and executive localparts" do
    exec = insert_agent("exec.agent", "Exec Agent", "Chief of Staff")
    head = insert_agent("mary.jones", "Mary Jones", "Chief Investment Officer")
    lead = insert_agent("brooke.hall", "Brooke Hall", "Engineering Lead, Voice AI")
    staff = insert_agent("mike.brown", "Mike Brown", "Equity Research Analyst")

    assert OrgChart.role_for(exec) == "executive"
    assert OrgChart.role_for(head) == "department_head"
    assert OrgChart.role_for(lead) == "team_lead"
    assert OrgChart.role_for(staff) == "staff"
  end

  test "role grants gate tool availability by role" do
    :ok = ToolRoles.replace_grants("create_matrix_room", ["executive", "department_head"])
    :ok = ToolRoles.replace_grants("delete_matrix_room", ["executive"])

    exec = insert_agent("exec.agent", "Exec Agent", "Chief of Staff")
    head = insert_agent("mary.jones", "Mary Jones", "Chief Investment Officer")
    staff = insert_agent("mike.brown", "Mike Brown", "Equity Research Analyst")

    exec_tools = Executor.available_tools(exec.id) |> Enum.map(& &1.name)
    head_tools = Executor.available_tools(head.id) |> Enum.map(& &1.name)
    staff_tools = Executor.available_tools(staff.id) |> Enum.map(& &1.name)

    assert "create_matrix_room" in exec_tools
    assert "delete_matrix_room" in exec_tools

    assert "create_matrix_room" in head_tools
    refute "delete_matrix_room" in head_tools

    refute "create_matrix_room" in staff_tools
    refute "delete_matrix_room" in staff_tools
  end

  test "an explicit per-agent permission row overrides the role mapping" do
    :ok = ToolRoles.replace_grants("delete_matrix_room", ["executive"])

    staff = insert_agent("mike.brown", "Mike Brown", "Equity Research Analyst")

    refute "delete_matrix_room" in (Executor.available_tools(staff.id) |> Enum.map(& &1.name))

    {:ok, _permission} =
      Agents.set_tool_permission(%{
        agent_id: staff.id,
        tool_name: "delete_matrix_room",
        scope: "default",
        allowed: true
      })

    assert "delete_matrix_room" in (Executor.available_tools(staff.id) |> Enum.map(& &1.name))
  end

  test "tools without grants follow the default policy" do
    :ok = ToolRoles.replace_grants("delete_matrix_room", [])

    staff = insert_agent("mike.brown", "Mike Brown", "Equity Research Analyst")

    # no grants -> default (available to everyone as a non-privileged tool)
    assert "delete_matrix_room" in (Executor.available_tools(staff.id) |> Enum.map(& &1.name))
  end
end
