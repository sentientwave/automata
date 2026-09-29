defmodule SentientwaveAutomata.Agents.Tools.CreateDepartment do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  @impl true
  def name, do: "create_department"

  @impl true
  def description do
    "Form a new department in the org chart (name, mission, optional head localpart)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "Department name"},
        "mission" => %{"type" => "string", "description" => "Department mission"},
        "head" => %{"type" => "string", "description" => "Optional head's localpart"}
      },
      "required" => ["name"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "create_department",
      args,
      opts,
      :create_failed
    )
  end
end

defmodule SentientwaveAutomata.Agents.Tools.CreateTeam do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  @impl true
  def name, do: "create_team"

  @impl true
  def description do
    "Form a new team inside a department (name, department, mission, optional team lead localpart)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "Team name"},
        "department" => %{"type" => "string", "description" => "Parent department name"},
        "mission" => %{"type" => "string", "description" => "Team mission"},
        "head" => %{"type" => "string", "description" => "Optional team lead's localpart"}
      },
      "required" => ["name", "department"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch("create_team", args, opts, :create_failed)
  end
end

defmodule SentientwaveAutomata.Agents.Tools.SetReportsTo do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  @impl true
  def name, do: "set_reports_to"

  @impl true
  def description do
    "Set who an agent reports to (use an empty reports_to to detach). Returns the new " <>
      "manager and the agent's own direct reports."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "localpart" => %{"type" => "string", "description" => "The agent whose manager changes"},
        "reports_to" => %{
          "type" => "string",
          "description" => "New manager's localpart (empty = nobody)"
        }
      },
      "required" => ["localpart"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "set_reports_to",
      args,
      opts,
      :update_failed
    )
  end
end

defmodule SentientwaveAutomata.Agents.Tools.AssignOrgUnit do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  @impl true
  def name, do: "assign_org_unit"

  @impl true
  def description do
    "Assign an agent to a department and/or team (updates their org chart placement)."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "localpart" => %{"type" => "string", "description" => "The agent to assign"},
        "department" => %{"type" => "string", "description" => "Department name"},
        "team" => %{"type" => "string", "description" => "Team name (optional)"}
      },
      "required" => ["localpart"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "assign_org_unit",
      args,
      opts,
      :update_failed
    )
  end
end

defmodule SentientwaveAutomata.Agents.Tools.DestroyDepartment do
  @moduledoc false
  @behaviour SentientwaveAutomata.Agents.Tools.Behaviour

  @impl true
  def name, do: "destroy_department"

  @impl true
  def description do
    "Destroy (remove) a department from the org chart by name. Members assigned to the " <>
      "department are NOT fired; they stay in place and are listed as warnings."
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "Department name to destroy"}
      },
      "required" => ["name"]
    }
  end

  @impl true
  def call(args, opts \\ []) when is_map(args) do
    SentientwaveAutomata.Agents.Tools.OpsJob.dispatch(
      "destroy_department",
      args,
      opts,
      :destroy_failed
    )
  end
end
