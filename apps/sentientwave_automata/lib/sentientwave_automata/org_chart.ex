defmodule SentientwaveAutomata.OrgChart do
  @moduledoc """
  Organization chart over the agent directory: org fields per agent,
  reporting lines, hiring, and firing.

  Org data lives on the agent profiles (sex, date of birth, company and job
  descriptions, reports_to localpart). Hiring and firing go through the
  directory manager so Matrix and the admin console stay in sync.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Agents.AgentProfile
  alias SentientwaveAutomata.DirectoryManager
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.SynapseAdmin
  alias SentientwaveAutomata.OrgChart.OrgUnit
  alias SentientwaveAutomata.Repo

  @doc """
  The standard company/community description applied to new hires.
  Configured via AUTOMATA_ORG_COMPANY_DESCRIPTION; empty by default.
  """
  def company_description do
    System.get_env("AUTOMATA_ORG_COMPANY_DESCRIPTION", "")
  end

  @doc """
  Localparts that hold the principal (top of org) role. Configured via
  AUTOMATA_ORG_PRINCIPAL_LOCALPARTS (comma separated); empty by default.
  """
  def principal_localparts do
    System.get_env("AUTOMATA_ORG_PRINCIPAL_LOCALPARTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

  @doc """
  Localparts that hold the executive role. Configured via
  AUTOMATA_ORG_EXECUTIVE_LOCALPARTS (comma separated); empty by default.
  """
  def executive_localparts do
    System.get_env("AUTOMATA_ORG_EXECUTIVE_LOCALPARTS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

  @doc """
  Computes the org role of an agent for role-based tool mapping:

  - "executive" — the executive office (chief of staff, principal's PA)
  - "department_head" — chiefs, directors, and heads of departments
  - "team_lead" — team leads
  - "staff" — everyone else
  """
  @spec role_for(AgentProfile.t()) :: String.t()
  def role_for(%AgentProfile{} = profile) do
    localpart = (profile.matrix_localpart || profile.slug) |> to_string() |> String.downcase()
    title = profile.metadata |> Map.get("title") |> to_string()

    cond do
      localpart in executive_localparts() -> "executive"
      Regex.match?(~r/\b(chief|director|head)\b/i, title) -> "department_head"
      Regex.match?(~r/\blead\b/i, title) -> "team_lead"
      true -> "staff"
    end
  end

  @doc "Computes an age in whole years from a date of birth."
  @spec age(nil | Date.t(), Date.t()) :: non_neg_integer() | nil
  def age(nil, _today), do: nil

  def age(%Date{} = dob, %Date{} = today) do
    base = Date.diff(today, dob)
    years = div(base, 365)

    birthday_passed? =
      Date.new(today.year, dob.month, dob.day)
      |> case do
        {:ok, this_year_birthday} -> Date.compare(this_year_birthday, today) in [:lt, :eq]
        _ -> false
      end

    if birthday_passed?, do: years, else: max(years - 1, 0)
  end

  @type org_entry :: %{
          localpart: String.t(),
          display_name: String.t(),
          title: String.t(),
          department: String.t(),
          team: String.t(),
          sex: String.t() | nil,
          date_of_birth: String.t() | nil,
          age: non_neg_integer() | nil,
          bio: String.t() | nil,
          company_description: String.t() | nil,
          job_description: String.t() | nil,
          reports_to: String.t() | nil,
          status: String.t()
        }

  @doc "Builds the org entry view for an agent profile."
  @spec entry(AgentProfile.t()) :: org_entry()
  def entry(%AgentProfile{} = profile) do
    %{
      localpart: profile.matrix_localpart || profile.slug,
      display_name: profile.display_name,
      title: profile.metadata |> Map.get("title"),
      department: profile.metadata |> Map.get("department"),
      team: profile.metadata |> Map.get("team"),
      sex: profile.sex,
      date_of_birth: profile.date_of_birth && Date.to_iso8601(profile.date_of_birth),
      age: age(profile.date_of_birth, Date.utc_today()),
      bio: profile.metadata |> Map.get("bio"),
      company_description: profile.company_description,
      job_description: profile.job_description,
      reports_to: profile.reports_to,
      status: Atom.to_string(profile.status)
    }
  end

  @doc "Lists the org chart (active agents), optionally rooted at a supervisor."
  @spec list_org(keyword()) :: [org_entry()]
  def list_org(opts \\ []) do
    AgentProfile
    |> org_scope(opts)
    |> order_by([a], asc: a.display_name)
    |> Repo.all()
    |> Enum.map(&entry/1)
  end

  @doc "Returns the org entry for a localpart."
  @spec get_by_localpart(String.t()) :: org_entry() | nil
  def get_by_localpart(localpart) do
    case Agents.get_agent_by_localpart(localpart) do
      %AgentProfile{status: :active} = profile -> entry(profile)
      _ -> nil
    end
  end

  @doc """
  Builds the visualization tree: roots (agents reporting outside the active
  org, e.g. to the principal) with nested children by reporting line.
  """
  @spec tree() :: [%{entry: org_entry(), children: [map()]}]
  def tree do
    entries = list_org()
    active_localparts = MapSet.new(entries, & &1.localpart)
    by_parent = Enum.group_by(entries, & &1.reports_to)

    roots =
      Enum.filter(entries, fn e -> not MapSet.member?(active_localparts, e.reports_to) end)

    tree = Enum.map(roots, &build_node(&1, by_parent, MapSet.new()))
    visited = collect_localparts(tree, MapSet.new())

    # Any entry not reachable from a root (e.g. members of a reporting-line
    # cycle) is appended as a root so it still appears in the org chart.
    leftovers =
      Enum.filter(entries, fn e -> not MapSet.member?(visited, e.localpart) end)

    tree ++ Enum.map(leftovers, &build_node(&1, by_parent, visited))
  end

  defp collect_localparts([], acc), do: acc

  defp collect_localparts([node | rest], acc) do
    acc = MapSet.put(acc, node.entry.localpart)
    collect_localparts(rest, collect_localparts(node.children, acc))
  end

  @doc """
  Computes a 2D layout for canvas visualization: every node gets an (x, y)
  position (x = horizontal slot, y = depth in reporting levels) and edges
  connect supervisors to their direct reports. Returns
  %{nodes: [map()], edges: [map()], width: float, height: float}.
  """
  @spec layout() :: map()
  def layout do
    tree = tree()
    {laid_out, max_slot, max_depth} = assign_layout_slots(tree, 0, 0)

    nodes =
      laid_out
      |> flatten_nodes()
      |> Enum.map(fn node ->
        entry = node.entry

        %{
          localpart: entry.localpart,
          name: entry.display_name,
          title: entry.title,
          department: entry.department,
          sex: entry.sex,
          age: entry.age,
          reports_to: entry.reports_to,
          report_count: length(node.children),
          x: node.x,
          y: node.depth,
          depth: node.depth
        }
      end)

    edges =
      laid_out
      |> flatten_nodes()
      |> Enum.flat_map(fn node ->
        case entry_reports_to(node) do
          nil -> []
          parent -> [%{from: parent, to: node.entry.localpart}]
        end
      end)

    %{
      nodes: nodes,
      edges: edges,
      width: max_slot,
      height: max_depth
    }
  end

  defp flatten_nodes(nodes), do: do_flatten_nodes(nodes, [])

  defp do_flatten_nodes([], acc), do: acc

  defp do_flatten_nodes([node | rest], acc) do
    do_flatten_nodes(rest, do_flatten_nodes(node.children, [node | acc]))
  end

  defp assign_layout_slots(children, slot, depth) do
    {laid, _next_slot} = do_assign_layout_slots(children, slot, depth)
    max_slot = laid |> Enum.map(& &1.x) |> Enum.max(fn -> 0 end)
    max_depth = laid |> Enum.map(& &1.depth) |> Enum.max(fn -> 0 end)
    {laid, max_slot, max_depth}
  end

  # a leaf consumes exactly one horizontal slot
  defp do_assign_layout_slots([], slot, _depth), do: {[], slot + 1}

  defp do_assign_layout_slots(nodes, slot, depth) do
    Enum.map_reduce(nodes, slot, fn node, current_slot ->
      {children, child_slot} = do_assign_layout_slots(node.children, current_slot, depth + 1)

      x =
        case children do
          [] -> current_slot + 0.5
          _ -> (children |> Enum.map(& &1.x) |> Enum.sum()) / length(children)
        end

      updated =
        node
        |> Map.put(:x, x)
        |> Map.put(:depth, depth)
        |> Map.put(:children, children)

      {updated, child_slot}
    end)
  end

  defp entry_reports_to(node), do: node.entry.reports_to

  @doc "Distinct departments across the active org."
  @spec departments() :: [String.t()]
  def departments do
    list_org()
    |> Enum.map(& &1.department)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Cycle-safe: a reporting-line cycle (data bug) must never make the tree
  # traversal recurse forever — the second visit caps the branch.
  defp build_node(entry, by_parent, visited) do
    if MapSet.member?(visited, entry.localpart) do
      %{entry: entry, children: []}
    else
      visited = MapSet.put(visited, entry.localpart)

      children =
        Map.get(by_parent, entry.localpart, [])
        |> Enum.sort_by(& &1.display_name)
        |> Enum.map(&build_node(&1, by_parent, visited))

      %{entry: entry, children: children}
    end
  end

  @doc "Direct reports of the given localpart."
  @spec direct_reports(String.t()) :: [org_entry()]
  def direct_reports(localpart) do
    AgentProfile
    |> where([a], a.reports_to == ^localpart and a.status == :active)
    |> order_by([a], asc: a.display_name)
    |> Repo.all()
    |> Enum.map(&entry/1)
  end

  @doc """
  Searches the org chart by name, title, department, team, or localpart.
  """
  @spec search(String.t(), keyword()) :: [org_entry()]
  def search(query_text, opts \\ []) do
    query = query_text |> to_string() |> String.trim()
    limit = Keyword.get(opts, :limit, 10)

    if query == "" do
      []
    else
      like = "%" <> query <> "%"

      AgentProfile
      |> org_scope(opts)
      |> where(
        [a],
        ilike(a.display_name, ^like) or
          ilike(coalesce(a.matrix_localpart, a.slug), ^like) or
          ilike(coalesce(a.job_description, ""), ^like) or
          ilike(fragment("coalesce(?->>'title', '')", a.metadata), ^like) or
          ilike(fragment("coalesce(?->>'department', '')", a.metadata), ^like) or
          ilike(fragment("coalesce(?->>'team', '')", a.metadata), ^like) or
          ilike(coalesce(a.reports_to, ""), ^like)
      )
      |> order_by([a], asc: a.display_name)
      |> limit(^limit)
      |> Repo.all()
      |> Enum.map(&entry/1)
    end
  end

  @doc "Hires a new agent into the org chart (and Matrix + the admin console)."
  @spec hire(map()) :: {:ok, map()} | {:error, term()}
  def hire(attrs) when is_map(attrs) do
    localpart = normalize_localpart(Map.get(attrs, "localpart", Map.get(attrs, :localpart, "")))
    display_name = attrs |> Map.get("display_name", localpart) |> to_string() |> String.trim()

    reports_to =
      normalize_localpart(Map.get(attrs, "reports_to", Map.get(attrs, :reports_to, "")))

    with {:ok, localpart} <- validate_hire_localpart(localpart),
         :ok <- validate_manager(localpart, reports_to),
         {:ok, result} <-
           DirectoryManager.create_user(%{
             localpart: localpart,
             kind: "agent",
             display_name: display_name,
             metadata: hire_metadata(attrs)
           }),
         %AgentProfile{} = profile <- Agents.ensure_agent_from_directory(localpart),
         {:ok, profile} <- set_org_fields(profile, display_name, attrs, localpart) do
      {:ok, Map.put(entry(profile), :generated_password, result.generated_password)}
    end
  end

  defp set_org_fields(%AgentProfile{} = profile, display_name, attrs, localpart) do
    directory_metadata =
      case Directory.get_user(localpart) do
        %{metadata: metadata} when is_map(metadata) -> metadata
        _ -> %{}
      end

    Agents.upsert_agent(%{
      slug: profile.slug,
      kind: :agent,
      display_name: display_name,
      matrix_localpart: localpart,
      status: :active,
      metadata: Map.merge(profile.metadata, directory_metadata),
      sex: Map.get(attrs, "sex", Map.get(attrs, :sex)),
      date_of_birth:
        normalize_dob(Map.get(attrs, "date_of_birth", Map.get(attrs, :date_of_birth))),
      company_description:
        presence(Map.get(attrs, "company_description")) || presence(company_description()),
      job_description: presence(Map.get(attrs, "job_description")),
      reports_to: normalize_localpart(Map.get(attrs, "reports_to", "")) |> presence()
    })
  end

  @doc "Fires an agent: removes them from the org chart, admin console, and Matrix."
  @spec fire(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def fire(localpart) do
    normalized = normalize_localpart(localpart)

    cond do
      normalized == "" ->
        {:error, :missing_localpart}

      true ->
        result =
          case DirectoryManager.deactivate_user(normalized) do
            {:ok, warnings} ->
              {:ok, warnings}

            {:error, :not_found} ->
              # No directory row (e.g. test fixtures): disable the agent
              # profile directly AND still deactivate the Matrix account,
              # so all stores stay consistent after a fire.
              disable_agent_profile(normalized)

              warnings =
                case SynapseAdmin.deactivate_user(normalized) do
                  :ok -> ["matrix account #{normalized} deactivated"]
                  {:error, reason} -> ["matrix deactivation failed: #{inspect(reason)}"]
                end

              {:ok, warnings}

            {:error, reason} ->
              {:error, reason}
          end

        with {:ok, warnings} <- result do
          # also clear reporting lines pointing at the fired agent
          {_count, _} =
            Repo.update_all(
              from(a in AgentProfile, where: a.reports_to == ^normalized),
              set: [reports_to: nil]
            )

          {:ok, warnings}
        end
    end
  end

  defp disable_agent_profile(localpart) do
    case Agents.get_agent_by_localpart(localpart) do
      %AgentProfile{} = profile ->
        _ =
          Agents.upsert_agent(%{
            slug: profile.slug,
            kind: profile.kind,
            display_name: profile.display_name,
            matrix_localpart: profile.matrix_localpart,
            status: :disabled,
            metadata: profile.metadata,
            sex: profile.sex,
            date_of_birth: profile.date_of_birth,
            company_description: profile.company_description,
            job_description: profile.job_description,
            reports_to: profile.reports_to
          })

        :ok

      nil ->
        :ok
    end
  end

  @doc "Updates org fields for an existing agent."
  @spec update_org_fields(String.t(), map()) :: {:ok, org_entry()} | {:error, term()}
  def update_org_fields(localpart, attrs) do
    normalized = normalize_localpart(localpart)

    case Agents.get_agent_by_localpart(normalized) do
      %AgentProfile{} = profile ->
        target =
          attrs
          |> Map.get("reports_to", profile.reports_to)
          |> normalize_localpart()
          |> presence()

        display_name = presence(Map.get(attrs, "display_name")) || profile.display_name

        with :ok <- validate_reporting_change(normalized, target),
             {:ok, updated} <-
               Agents.upsert_agent(%{
                 slug: profile.slug,
                 kind: profile.kind,
                 display_name: display_name,
                 matrix_localpart: profile.matrix_localpart,
                 status: profile.status,
                 metadata: profile.metadata,
                 sex: Map.get(attrs, "sex", profile.sex),
                 date_of_birth: Map.get(attrs, "date_of_birth", profile.date_of_birth),
                 company_description:
                   Map.get(attrs, "company_description", profile.company_description),
                 job_description: Map.get(attrs, "job_description", profile.job_description),
                 reports_to: target
               }) do
          {:ok, entry(updated)}
        else
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, :not_found}
    end
  end

  @doc "Lists org units (departments and teams)."
  @spec list_units(keyword()) :: [map()]
  def list_units(opts \\ []) do
    OrgUnit
    |> maybe_filter_unit_kind(Keyword.get(opts, :kind))
    |> maybe_filter_unit_department(Keyword.get(opts, :department))
    |> order_by([u], asc: u.name)
    |> Repo.all()
    |> Enum.map(&unit_entry/1)
  end

  @doc "Creates an org unit (department or team)."
  @spec create_unit(map()) :: {:ok, map()} | {:error, term()}
  def create_unit(attrs) when is_map(attrs) do
    kind = normalize_unit_kind(Map.get(attrs, "kind", Map.get(attrs, :kind, "team")))

    %OrgUnit{}
    |> OrgUnit.changeset(%{
      name: presence(Map.get(attrs, "name", Map.get(attrs, :name))),
      kind: kind,
      department: presence(Map.get(attrs, "department", Map.get(attrs, :department))),
      mission: presence(Map.get(attrs, "mission", Map.get(attrs, :mission))),
      head: normalize_localpart(Map.get(attrs, "head", Map.get(attrs, :head, ""))) |> presence()
    })
    |> Repo.insert()
    |> case do
      {:ok, unit} -> {:ok, unit_entry(unit)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Removes an org unit by name and kind."
  @spec delete_unit(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_unit(name, kind) do
    from(u in OrgUnit, where: u.name == ^name and u.kind == ^normalize_unit_kind(kind))
    |> Repo.delete_all()
    |> case do
      {_count, nil} -> :ok
      {_count, _result} -> :ok
    end
  end

  @doc """
  Sets who an agent reports to (and returns both directions: the new manager
  and the agent's own direct reports).
  """
  @spec set_reports_to(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def set_reports_to(localpart, reports_to) do
    normalized = normalize_localpart(localpart)
    target = normalize_localpart(reports_to) |> presence()

    cond do
      target == normalized ->
        {:error, :self_report_cycle}

      would_create_reporting_cycle?(normalized, target) ->
        {:error, :reporting_cycle}

      true ->
        do_set_reports_to(normalized, target)
    end
  end

  defp do_set_reports_to(normalized, target) do
    case Agents.get_agent_by_localpart(normalized) do
      %AgentProfile{} = profile ->
        Agents.upsert_agent(%{
          slug: profile.slug,
          kind: profile.kind,
          display_name: profile.display_name,
          matrix_localpart: profile.matrix_localpart,
          status: profile.status,
          metadata: profile.metadata,
          sex: profile.sex,
          date_of_birth: profile.date_of_birth,
          company_description: profile.company_description,
          job_description: profile.job_description,
          reports_to: target
        })
        |> case do
          {:ok, updated} ->
            {:ok,
             %{
               "localpart" => updated.matrix_localpart || updated.slug,
               "reports_to" => updated.reports_to,
               "direct_reports" => direct_reports(updated.matrix_localpart || updated.slug)
             }}

          {:error, changeset} ->
            {:error, changeset}
        end

      nil ->
        {:error, :agent_not_found}
    end
  end

  defp validate_reporting_change(localpart, target) do
    cond do
      target == localpart -> {:error, :self_report_cycle}
      would_create_reporting_cycle?(localpart, target) -> {:error, :reporting_cycle}
      true -> :ok
    end
  end

  # Walks the reporting chain upward from `target`; a cycle exists when it
  # reaches `localpart` again. Non-agent managers terminate the walk.
  defp would_create_reporting_cycle?(_localpart, nil), do: false
  defp would_create_reporting_cycle?(_localpart, ""), do: false

  defp would_create_reporting_cycle?(localpart, target) do
    walk_reporting_chain(target, localpart, MapSet.new())
  end

  defp walk_reporting_chain(current, stop, visited) do
    cond do
      current == stop ->
        true

      MapSet.member?(visited, current) ->
        false

      true ->
        case Agents.get_agent_by_localpart(current) do
          %AgentProfile{reports_to: next} when is_binary(next) and next != "" ->
            walk_reporting_chain(next, stop, MapSet.put(visited, current))

          _ ->
            false
        end
    end
  end

  @doc "Assigns an agent to a department/team (updates the org metadata)."
  @spec assign_org_unit(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def assign_org_unit(localpart, attrs) do
    case Agents.get_agent_by_localpart(normalize_localpart(localpart)) do
      %AgentProfile{} = profile ->
        department =
          presence(Map.get(attrs, "department", Map.get(attrs, :department))) ||
            Map.get(profile.metadata, "department")

        team =
          presence(Map.get(attrs, "team", Map.get(attrs, :team))) ||
            Map.get(profile.metadata, "team")

        metadata =
          profile.metadata
          |> maybe_put("department", department)
          |> maybe_put("team", team)

        Agents.upsert_agent(%{
          slug: profile.slug,
          kind: profile.kind,
          display_name: profile.display_name,
          matrix_localpart: profile.matrix_localpart,
          status: profile.status,
          metadata: metadata,
          sex: profile.sex,
          date_of_birth: profile.date_of_birth,
          company_description: profile.company_description,
          job_description: profile.job_description,
          reports_to: profile.reports_to
        })
        |> case do
          {:ok, updated} -> {:ok, entry(updated)}
          {:error, changeset} -> {:error, changeset}
        end

      nil ->
        {:error, :agent_not_found}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp unit_entry(%OrgUnit{} = unit) do
    %{
      name: unit.name,
      kind: unit.kind,
      department: unit.department,
      mission: unit.mission,
      head: unit.head
    }
  end

  defp maybe_filter_unit_kind(query, nil), do: query
  defp maybe_filter_unit_kind(query, ""), do: query

  defp maybe_filter_unit_kind(query, kind),
    do: where(query, [u], u.kind == ^normalize_unit_kind(kind))

  defp maybe_filter_unit_department(query, nil), do: query
  defp maybe_filter_unit_department(query, ""), do: query

  defp maybe_filter_unit_department(query, department),
    do: where(query, [u], u.department == ^department)

  defp normalize_unit_kind(value) when value in ["department", "team"], do: value
  defp normalize_unit_kind(value) when value in [:department, :team], do: Atom.to_string(value)
  defp normalize_unit_kind(_), do: "team"

  defp org_scope(query, opts) do
    base = where(query, [a], a.kind == :agent and a.status == :active)

    case Keyword.get(opts, :department) do
      dep when is_binary(dep) and dep != "" ->
        where(base, [a], fragment("(?->>'department')", a.metadata) == ^dep)

      _ ->
        base
    end
  end

  defp hire_metadata(attrs) do
    %{
      "title" => presence(Map.get(attrs, "title")),
      "department" => presence(Map.get(attrs, "department")),
      "team" => presence(Map.get(attrs, "team")),
      "bio" => presence(Map.get(attrs, "bio")),
      "focus" => presence(Map.get(attrs, "focus")),
      "virtual_ai" => true
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp validate_hire_localpart(localpart) do
    cond do
      localpart == "" -> {:error, :missing_localpart}
      Directory.get_user(localpart) != nil -> {:error, :localpart_taken}
      Agents.get_agent_by_localpart(localpart) != nil -> {:error, :localpart_taken}
      true -> {:ok, localpart}
    end
  end

  defp validate_manager(_localpart, ""), do: :ok

  defp validate_manager(_localpart, reports_to) do
    known_agent =
      case Agents.get_agent_by_localpart(reports_to) do
        %AgentProfile{status: :active} -> true
        _ -> false
      end

    if known_agent or reports_to in principal_localparts() do
      :ok
    else
      {:error, {:unknown_manager, reports_to}}
    end
  end

  defp normalize_dob(nil), do: nil

  defp normalize_dob(%Date{} = date), do: date

  defp normalize_dob(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp normalize_dob(_), do: nil

  defp normalize_localpart(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("@")
    |> String.split(":", parts: 2)
    |> List.first()
    |> String.downcase()
  end

  # Note: the Temporal JSON externalizer (Erlang `json` lib) mangles nulls —
  # Elixir nil round-trips as the "nil"/"null" strings or :null/:nil atoms —
  # so all of those count as absent here.
  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(:null), do: nil
  defp presence("nil"), do: nil
  defp presence("null"), do: nil
  defp presence(value), do: value |> to_string() |> String.trim()
end
