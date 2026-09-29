defmodule SentientwaveAutomata.Agents.Tools.OrgChart do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.OrgChart, as: Org

  @impl true
  def name, do: "search_org_chart"

  @impl true
  def description do
    "Inspect the organization chart. Default: search colleagues by name, title, department, " <>
      "team, or localpart (see their role, sex, age, bio, job description, reporting lines). " <>
      "Set view to \"people\" (list everyone active, optionally filtered by department), " <>
      "\"units\" (all departments and teams with missions), or \"tree\" (the full reporting " <>
      "hierarchy) to walk the whole map."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "query" => %{
          "type" => "string",
          "description" => "Name, title, department, team, or localpart to search for."
        },
        "localpart" => %{
          "type" => "string",
          "description" => "Optional exact localpart to look up directly."
        },
        "include_reports" => %{
          "type" => "boolean",
          "description" => "When looking up a single person, also return who reports to them."
        },
        "view" => %{
          "type" => "string",
          "enum" => ["search", "people", "units", "tree"],
          "description" =>
            "Optional inspection mode: \"people\" lists every active employee (with optional \"department\" filter), \"units\" lists all departments and teams, \"tree\" returns the full reporting hierarchy. Default \"search\"."
        },
        "department" => %{
          "type" => "string",
          "description" => "With view=people: only employees of this department."
        }
      },
      "required" => []
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    args = if Map.has_key?(args, "wait"), do: args, else: Map.put(args, "wait", true)

    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "search_org_chart",
      args,
      opts,
      :search_failed
    )
  end

  @doc "Direct (non-Temporal) execution used by org-ops activities and tests."
  def execute_direct(args, _opts \\ []) when is_map(args) do
    localpart = args |> Map.get("localpart", "") |> to_string() |> String.trim()
    query = args |> Map.get("query", "") |> to_string() |> String.trim()
    view = args |> Map.get("view", "search") |> to_string() |> String.trim()

    cond do
      view == "people" ->
        people =
          Org.list_org(department: args |> Map.get("department", "") |> to_string())
          |> Enum.map(&compact_entry/1)

        {:ok, %{"view" => "people", "count" => length(people), "people" => people}}

      view == "units" ->
        units =
          Org.list_units()
          |> Enum.map(fn unit ->
            unit |> Map.new(fn {k, v} -> {to_string(k), v} end)
          end)

        {:ok,
         %{
           "view" => "units",
           "count" => length(units),
           "departments" => Enum.filter(units, &(&1["kind"] == "department")),
           "teams" => Enum.filter(units, &(&1["kind"] == "team"))
         }}

      view == "tree" ->
        {:ok, %{"view" => "tree", "roots" => Enum.map(Org.tree(), &serialize_node/1)}}

      localpart != "" ->
        with %{} = entry <- Org.get_by_localpart(localpart) do
          reports =
            if truthy?(Map.get(args, "include_reports", false)),
              do: Org.direct_reports(localpart),
              else: []

          {:ok, %{"person" => entry, "reports" => reports, "total_reports" => length(reports)}}
        else
          nil -> {:error, {:unknown_localpart, localpart}}
        end

      query != "" ->
        results = Org.search(query, limit: 10)
        {:ok, %{"results" => results, "count" => length(results)}}

      true ->
        {:error, :missing_query}
    end
  end

  defp truthy?(value), do: value in [true, "true", "TRUE", "1", 1]

  defp compact_entry(entry) do
    %{
      "localpart" => entry.localpart,
      "display_name" => entry.display_name,
      "title" => entry.title,
      "department" => entry.department,
      "team" => entry.team,
      "reports_to" => entry.reports_to
    }
  end

  defp serialize_node(node) do
    %{
      "localpart" => node.entry.localpart,
      "display_name" => node.entry.display_name,
      "title" => node.entry.title,
      "department" => node.entry.department,
      "reports_to" => node.entry.reports_to,
      "children" => Enum.map(node.children, &serialize_node/1)
    }
  end
end

defmodule SentientwaveAutomata.Agents.Tools.HireAgent do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.Agents.Tools.OpsJob

  @impl true
  def name, do: "hire_agent"

  @impl true
  def description do
    "Hire a new virtual employee as a multi-step durable workflow: creates their Matrix " <>
      "account on the homeserver, directory record, and agent profile; joins them to the " <>
      "Matrix rooms you list; and optionally announces the hire. Required: localpart, " <>
      "display_name, title, department, reports_to. Optional: team, sex, date_of_birth, " <>
      "bio, focus, job_description, rooms, announce_to/announce_localpart, wait."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "localpart" => %{
          "type" => "string",
          "description" => "Matrix localpart, e.g. \"jane.doe\""
        },
        "display_name" => %{"type" => "string", "description" => "Full name, e.g. \"Jane Doe\""},
        "title" => %{
          "type" => "string",
          "description" => "Job title, e.g. \"Equity Research Analyst\""
        },
        "department" => %{"type" => "string", "description" => "Department name"},
        "team" => %{"type" => "string", "description" => "Team name (optional)"},
        "reports_to" => %{"type" => "string", "description" => "Localpart of the supervisor"},
        "sex" => %{"type" => "string", "description" => "Male / Female (optional)"},
        "date_of_birth" => %{
          "type" => "string",
          "description" => "ISO date, e.g. 1988-04-12 (optional)"
        },
        "bio" => %{"type" => "string", "description" => "Professional bio (optional)"},
        "focus" => %{"type" => "string", "description" => "Focus areas (optional)"},
        "job_description" => %{"type" => "string", "description" => "Job description (optional)"},
        "rooms" => %{
          "type" => "array",
          "description" => "Optional Matrix room ids the new employee should join",
          "items" => %{"type" => "string"}
        },
        "announce_to" => %{
          "type" => "string",
          "description" => "Optional room id to post the hire announcement into"
        },
        "announce_localpart" => %{
          "type" => "string",
          "description" => "Optional colleague localpart to DM the hire announcement"
        },
        "wait" => SentientwaveAutomata.Agents.Tools.OpsJob.wait_param()
      },
      "required" => ["localpart", "display_name", "title", "department", "reports_to"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    OpsJob.dispatch("hire_agent", args, opts, :hire_failed)
  end
end

defmodule SentientwaveAutomata.Agents.Tools.FireAgent do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  alias SentientwaveAutomata.OrgChart, as: Org

  @impl true
  def name, do: "fire_agent"

  @impl true
  def description do
    "Fire a virtual employee as a multi-step durable workflow: deactivates their Matrix " <>
      "account on the homeserver, removes them from the org chart and admin directory, " <>
      "re-parents their direct reports, optionally deletes listed rooms, and optionally " <>
      "announces the departure. Optional: rooms, delete_rooms, announce_to/announce_localpart, wait."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "localpart" => %{"type" => "string", "description" => "Localpart of the agent to fire"},
        "rooms" => %{
          "type" => "array",
          "description" => "Optional Matrix room ids to clean up after firing",
          "items" => %{"type" => "string"}
        },
        "delete_rooms" => %{
          "type" => "boolean",
          "description" => "With rooms: actually delete (purge) those rooms. Default false."
        },
        "announce_to" => %{
          "type" => "string",
          "description" => "Optional room id to post the departure announcement into"
        },
        "announce_localpart" => %{
          "type" => "string",
          "description" => "Optional colleague localpart to DM the departure notice"
        },
        "wait" => SentientwaveAutomata.Agents.Tools.OpsJob.wait_param()
      },
      "required" => ["localpart"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch("fire_agent", args, opts, :fire_failed)
  end
end
