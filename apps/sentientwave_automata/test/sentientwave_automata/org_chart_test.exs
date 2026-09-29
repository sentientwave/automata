defmodule SentientwaveAutomata.OrgChartTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.AgentProfile
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.OrgChart
  alias SentientwaveAutomata.Repo

  defp insert_agent(lp, name, opts \\ %{}) do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: lp,
        kind: :agent,
        display_name: name,
        matrix_localpart: lp,
        status: :active,
        metadata: Map.get(opts, :metadata, %{}),
        sex: Map.get(opts, :sex),
        date_of_birth: Map.get(opts, :dob),
        company_description: Map.get(opts, :company, "Example Org"),
        job_description: Map.get(opts, :job, "Serves the organization."),
        reports_to: Map.get(opts, :reports_to)
      })

    profile
  end

  test "computes age from date of birth" do
    assert OrgChart.age(~D[1990-06-15], ~D[2026-08-13]) == 36
    assert OrgChart.age(~D[1990-08-15], ~D[2026-08-13]) == 35
    assert OrgChart.age(nil, ~D[2026-08-13]) == nil
  end

  test "search finds agents by name, title, department, and localpart" do
    _ =
      insert_agent("jane.doe", "Jane Doe", %{
        metadata: %{
          "title" => "Personal Cybersecurity Risk Analyst",
          "department" => "Wealth Planning & Tax Department"
        },
        sex: "Male",
        dob: ~D[1988-04-12]
      })

    assert [entry] = OrgChart.search("Jane")
    assert entry.localpart == "jane.doe"
    assert entry.age != nil
    assert entry.sex == "Male"

    assert [entry] = OrgChart.search("Cybersecurity")
    assert entry.localpart == "jane.doe"

    assert [entry] = OrgChart.search("jane.doe")
    assert entry.localpart == "jane.doe"
  end

  test "lists direct reports" do
    _ = insert_agent("mary.jones", "Mary Jones")
    _ = insert_agent("mike.brown", "Mike Brown", %{reports_to: "mary.jones"})
    _ = insert_agent("sarah.lee", "Sarah Lee", %{reports_to: "mary.jones"})
    _ = insert_agent("elena.ramos", "Elena Ramos", %{reports_to: "john.smith"})

    reports = OrgChart.direct_reports("mary.jones")
    assert length(reports) == 2
    assert Enum.any?(reports, &(&1.localpart == "mike.brown"))
    assert Enum.any?(reports, &(&1.localpart == "sarah.lee"))
  end

  test "hire creates directory user, agent profile, and org fields" do
    previous = System.get_env("AUTOMATA_ORG_COMPANY_DESCRIPTION")
    System.put_env("AUTOMATA_ORG_COMPANY_DESCRIPTION", "Example Org")

    _ = insert_agent("mary.jones", "Mary Jones")

    on_exit(fn ->
      if previous,
        do: System.put_env("AUTOMATA_ORG_COMPANY_DESCRIPTION", previous),
        else: System.delete_env("AUTOMATA_ORG_COMPANY_DESCRIPTION")
    end)

    assert {:ok, entry} =
             OrgChart.hire(%{
               "localpart" => "jane.doe",
               "display_name" => "Jane Doe",
               "title" => "Equity Research Analyst",
               "department" => "Investments Department",
               "team" => "Public Markets Team",
               "reports_to" => "mary.jones",
               "sex" => "Female",
               "date_of_birth" => "1992-03-11",
               "job_description" => "Covers consumer equities."
             })

    assert entry.localpart == "jane.doe"
    assert entry.sex == "Female"
    assert entry.date_of_birth == "1992-03-11"
    assert entry.reports_to == "mary.jones"
    assert entry.company_description =~ "Example Org"

    # directory user exists (admin console)
    assert Directory.get_user("jane.doe") != nil
    # agent profile exists with org fields
    assert %AgentProfile{job_description: "Covers consumer equities."} =
             Agents.get_agent_by_localpart("jane.doe")
  end

  test "fire removes the agent from the org and clears reporting lines" do
    _ = insert_agent("jane.doe", "Jane Doe")
    _ = insert_agent("subordinate.one", "Subordinate One", %{reports_to: "jane.doe"})

    assert {:ok, _warnings} = OrgChart.fire("jane.doe")

    assert OrgChart.get_by_localpart("jane.doe") == nil

    subordinate = Repo.get_by!(AgentProfile, matrix_localpart: "subordinate.one")
    assert subordinate.reports_to == nil
  end

  test "hire rejects taken localparts" do
    _ = insert_agent("jane.doe", "Jane Doe")
    assert {:error, :localpart_taken} = OrgChart.hire(%{"localpart" => "jane.doe"})
  end
end

defmodule SentientwaveAutomata.OrgChartTreeTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.OrgChart

  defp insert_agent(lp, name, reports_to) do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: lp,
        kind: :agent,
        display_name: name,
        matrix_localpart: lp,
        status: :active,
        metadata: %{"title" => "Analyst", "department" => "Investments Department"},
        reports_to: reports_to
      })

    profile
  end

  test "builds the reporting tree with roots and nested children" do
    _ = insert_agent("mary.jones", "Mary Jones", "boss")
    _ = insert_agent("mike.brown", "Mike Brown", "mary.jones")
    _ = insert_agent("sarah.lee", "Sarah Lee", "mary.jones")
    _ = insert_agent("intern.one", "Intern One", "mike.brown")

    tree = OrgChart.tree()

    assert [%{entry: %{localpart: "mary.jones"}, children: children}] = tree
    assert length(children) == 2

    assert Enum.map(children, & &1.entry.localpart) |> Enum.sort() == [
             "mike.brown",
             "sarah.lee"
           ]

    mike = Enum.find(children, &(&1.entry.localpart == "mike.brown"))
    assert [%{entry: %{localpart: "intern.one"}}] = mike.children
  end

  test "lists distinct departments" do
    _ = insert_agent("a.one", "A One", "boss")
    assert OrgChart.departments() == ["Investments Department"]
  end
end

defmodule SentientwaveAutomata.OrgChartLayoutTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.OrgChart

  defp insert_agent(lp, name, reports_to) do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: lp,
        kind: :agent,
        display_name: name,
        matrix_localpart: lp,
        status: :active,
        metadata: %{"title" => "Analyst"},
        reports_to: reports_to
      })

    profile
  end

  test "layout places every node with depth and edges" do
    _ = insert_agent("boss.one", "Boss One", "boss")
    _ = insert_agent("child.one", "Child One", "boss.one")
    _ = insert_agent("child.two", "Child Two", "boss.one")
    _ = insert_agent("grand.child", "Grand Child", "child.one")

    layout = OrgChart.layout()

    localparts = Enum.map(layout.nodes, & &1.localpart) |> Enum.sort()
    assert localparts == ["boss.one", "child.one", "child.two", "grand.child"]

    boss = Enum.find(layout.nodes, &(&1.localpart == "boss.one"))
    assert boss.depth == 0
    assert boss.report_count == 2

    # leaves spread horizontally (siblings get distinct slots)
    leaf_xs =
      layout.nodes
      |> Enum.filter(&(&1.report_count == 0))
      |> Enum.map(& &1.x)

    assert length(Enum.uniq(leaf_xs)) == length(leaf_xs)

    assert Enum.max(layout.nodes |> Enum.map(& &1.x)) -
             Enum.min(layout.nodes |> Enum.map(& &1.x)) >= 1.0

    grand = Enum.find(layout.nodes, &(&1.localpart == "grand.child"))
    assert grand.depth == 2

    edges = Enum.map(layout.edges, &{&1.from, &1.to}) |> Enum.sort()
    assert {"boss.one", "child.one"} in edges
    assert {"boss.one", "child.two"} in edges
    assert {"child.one", "grand.child"} in edges
  end
end

defmodule SentientwaveAutomata.OrgUnitTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.OrgChart

  defp insert_agent(lp, name, opts \\ %{}) do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: lp,
        kind: :agent,
        display_name: name,
        matrix_localpart: lp,
        status: :active,
        metadata: Map.get(opts, :metadata, %{"title" => "Analyst"}),
        reports_to: Map.get(opts, :reports_to)
      })

    profile
  end

  test "creates and lists departments and teams" do
    assert {:ok, dep} =
             OrgChart.create_unit(%{
               "name" => "Research Lab",
               "kind" => "department",
               "mission" => "Deep research"
             })

    assert dep.name == "Research Lab"
    assert dep.kind == "department"

    assert {:ok, team} =
             OrgChart.create_unit(%{
               "name" => "Lab Ops",
               "kind" => "team",
               "department" => "Research Lab",
               "mission" => "Runs the lab"
             })

    assert team.department == "Research Lab"

    assert Enum.any?(OrgChart.list_units(kind: "department"), &(&1.name == "Research Lab"))

    assert Enum.any?(
             OrgChart.list_units(kind: "team", department: "Research Lab"),
             &(&1.name == "Lab Ops")
           )
  end

  test "set_reports_to updates the manager and returns both directions" do
    _ = insert_agent("mary.jones", "Mary Jones")
    _ = insert_agent("mike.brown", "Mike Brown", %{reports_to: "mary.jones"})

    assert {:ok, result} = OrgChart.set_reports_to("mike.brown", "boss")
    assert result["reports_to"] == "boss"

    assert {:ok, result} = OrgChart.set_reports_to("mike.brown", "mary.jones")
    assert result["reports_to"] == "mary.jones"

    reports = OrgChart.direct_reports("mary.jones")
    assert Enum.any?(reports, &(&1.localpart == "mike.brown"))
  end

  test "assign_org_unit moves an agent between department and team" do
    _ = insert_agent("mike.brown", "Mike Brown")

    assert {:ok, entry} =
             OrgChart.assign_org_unit("mike.brown", %{
               "department" => "Research Lab",
               "team" => "Lab Ops"
             })

    assert entry.department == "Research Lab"
    assert entry.team == "Lab Ops"
  end
end

defmodule SentientwaveAutomata.OrgChartCycleTest do
  use SentientwaveAutomata.DataCase

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.OrgChart

  defp insert_agent(lp, name, reports_to) do
    {:ok, profile} =
      Agents.upsert_agent(%{
        slug: lp,
        kind: :agent,
        display_name: name,
        matrix_localpart: lp,
        status: :active,
        metadata: %{"title" => "Analyst"},
        reports_to: reports_to
      })

    profile
  end

  test "set_reports_to rejects self-reporting" do
    _ = insert_agent("boss.one", "Boss One", "boss")
    assert {:error, :self_report_cycle} = OrgChart.set_reports_to("boss.one", "boss.one")
  end

  test "set_reports_to rejects transitive cycles" do
    _ = insert_agent("a.one", "A One", "boss")
    _ = insert_agent("b.one", "B One", "a.one")

    # a reports to b while b already reports to a -> cycle
    assert {:error, :reporting_cycle} = OrgChart.set_reports_to("a.one", "b.one")
    # legal change still works
    assert {:ok, %{"reports_to" => "boss"}} = OrgChart.set_reports_to("b.one", "boss")
  end

  test "tree and layout survive a pre-existing cycle in the data" do
    # write a cycle directly at the data layer
    insert_agent("cycle.a", "Cycle A", "cycle.b")
    b = insert_agent("cycle.b", "Cycle B", "cycle.a")

    # force the cycle (bypassing set_reports_to guards)
    _ =
      Agents.upsert_agent(%{
        slug: b.slug,
        kind: :agent,
        display_name: b.display_name,
        matrix_localpart: b.matrix_localpart,
        status: :active,
        metadata: b.metadata,
        reports_to: "cycle.a"
      })

    tree = OrgChart.tree()
    layout = OrgChart.layout()

    assert is_list(tree)
    assert is_list(layout.nodes)
    assert length(layout.nodes) >= 1
  end

  test "hire rejects an unknown manager" do
    assert {:error, {:unknown_manager, "nobody.here"}} =
             OrgChart.hire(%{
               "localpart" => "jane.doe",
               "display_name" => "Jane Doe",
               "title" => "Analyst",
               "department" => "Research",
               "reports_to" => "nobody.here"
             })
  end
end

defmodule SentientwaveAutomata.OrgChartInspectViewsTest do
  use SentientwaveAutomata.DataCase, async: true

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.Tools.OrgChart

  defp insert_agent(lp, name, metadata, reports_to \\ nil) do
    {:ok, _} =
      Agents.upsert_agent(%{
        slug: lp,
        kind: :agent,
        display_name: name,
        matrix_localpart: lp,
        status: :active,
        metadata: metadata,
        company_description: "Example Org",
        job_description: "Serves.",
        reports_to: reports_to
      })
  end

  test "view=people lists active employees with optional department filter" do
    insert_agent("view.a", "View A", %{"department" => "Alpha", "title" => "Analyst"})
    insert_agent("view.b", "View B", %{"department" => "Beta"})
    insert_agent("view.c", "View C", %{"department" => "Alpha"})

    {:ok, all} = OrgChart.call(%{"view" => "people"})
    lps = Enum.map(all["people"], & &1["localpart"])
    assert Enum.sort(lps) == ["view.a", "view.b", "view.c"]

    {:ok, alpha} = OrgChart.call(%{"view" => "people", "department" => "Alpha"})
    assert alpha["count"] == 2
    assert Enum.all?(alpha["people"], &(&1["department"] == "Alpha"))
  end

  test "view=units lists departments and teams separately" do
    {:ok, _} =
      SentientwaveAutomata.OrgChart.create_unit(%{"kind" => "department", "name" => "Units Dept"})

    {:ok, _} =
      SentientwaveAutomata.OrgChart.create_unit(%{
        "kind" => "team",
        "department" => "Units Dept",
        "name" => "Units Team"
      })

    {:ok, result} = OrgChart.call(%{"view" => "units"})

    assert Enum.any?(result["departments"], &(&1["name"] == "Units Dept"))
    assert Enum.any?(result["teams"], &(&1["name"] == "Units Team"))
  end

  test "view=tree returns the reporting hierarchy" do
    insert_agent("tree.root", "Tree Root", %{"department" => "T"}, nil)
    insert_agent("tree.child", "Tree Child", %{"department" => "T"}, "tree.root")

    {:ok, result} = OrgChart.call(%{"view" => "tree"})

    root = Enum.find(result["roots"], &(&1["localpart"] == "tree.root"))
    assert root
    assert Enum.any?(root["children"], &(&1["localpart"] == "tree.child"))
  end
end
