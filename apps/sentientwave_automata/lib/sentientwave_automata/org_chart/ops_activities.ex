defmodule SentientwaveAutomata.OrgChart.OpsActivities do
  @moduledoc """
  Temporal activity entrypoint for org/chat operation workflows.

  Domain failures are returned as `%{"status" => "error"}` results instead of
  raising: raising would make Temporal retry and re-apply the side effect
  (duplicate hires / duplicate Matrix accounts). Activities are idempotent
  where possible; job recording is keyed by workflow_id so re-execution is
  safe (Temporal best practice).
  """

  use TemporalSdk.Activity

  alias SentientwaveAutomata.Agents.AgentProfile
  alias SentientwaveAutomata.Agents.Tools.BraveSearch
  alias SentientwaveAutomata.Agents.Tools.CreateMatrixRoom
  alias SentientwaveAutomata.Agents.Tools.DeleteMatrixRoom
  alias SentientwaveAutomata.Agents.Tools.OrgChart, as: OrgChartTool
  alias SentientwaveAutomata.Agents.Tools.OrgJobStatus
  alias SentientwaveAutomata.Agents.Tools.RunShell
  alias SentientwaveAutomata.Agents.Tools.SendMatrixMessage
  alias SentientwaveAutomata.Agents.Tools.SystemDirectoryAdmin
  alias SentientwaveAutomata.Matrix.SynapseAdmin
  alias SentientwaveAutomata.OrgChart, as: Org
  alias SentientwaveAutomata.OrgChart.Jobs
  alias SentientwaveAutomata.Repo

  @supported_ops [
    "hire_agent",
    "fire_agent",
    "create_department",
    "destroy_department",
    "create_team",
    "destroy_team",
    "set_reports_to",
    "assign_org_unit",
    "send_matrix_message",
    "create_matrix_room",
    "delete_matrix_room",
    "search_org_chart",
    "org_job_status",
    "system_directory_admin",
    "brave_search",
    "run_shell"
  ]

  def supported_ops, do: @supported_ops

  # Multi-step operations: each step is its own durable activity so Temporal
  # retries resume from the failed stage, and job progress reflects reality.
  @multi_step_ops %{
    "hire_agent" => [
      "ensure_department",
      "create_org_record",
      "provision_matrix_membership",
      "announce_hire"
    ],
    "fire_agent" => ["deactivate_account", "cleanup_rooms", "announce_departure"]
  }

  def multi_step_ops, do: @multi_step_ops

  def steps_for(op), do: Map.get(@multi_step_ops, op, [])

  @impl true
  def execute(_context, [%{"step" => "mark_running", "job_id" => job_id}])
      when is_binary(job_id) do
    _ = Jobs.mark_running(job_id)
    [%{"status" => "running"}]
  end

  # Workflows without a job row (started by hand via tctl) get no-op status
  # updates so the operation itself still runs and the workflow completes
  # instead of failing on the payload catch-all below. Temporal's JSON
  # externalizer decodes `null` as the :null atom, so both spellings count.
  def execute(_context, [%{"step" => "mark_running", "job_id" => job_id}])
      when is_nil(job_id) or job_id == :null or job_id == nil do
    [%{"status" => "running"}]
  end

  def execute(
        _context,
        [%{"step" => "record_result", "job_id" => job_id, "result" => result}]
      )
      when (is_nil(job_id) or job_id == :null or job_id == nil) and is_map(result) do
    [%{"status" => "recorded"}]
  end

  def execute(_context, [%{"step" => "record_result", "job_id" => job_id, "result" => result}])
      when is_binary(job_id) and is_map(result) do
    case result do
      %{"status" => "error"} ->
        Jobs.fail(job_id, result["reason"] || inspect(result))

      _ ->
        # Temporal's externalizer can round-trip nulls as :null/:nil atoms;
        # normalize them so stored JSON has real nulls, not "null" strings.
        Jobs.complete(job_id, normalize_external(result) |> Map.delete("via"))
    end

    [%{"status" => "recorded"}]
  end

  def execute(_context, [%{"step" => "apply_op", "op" => op, "args" => args}])
      when is_binary(op) and is_map(args) do
    if op in @supported_ops do
      [apply_op(op, normalize_args(args))]
    else
      fail_non_retryable("org_ops.unsupported_op", "unsupported org op: #{inspect(op)}")
    end
  end

  def execute(
        _context,
        [%{"step" => "run_step", "op" => op, "step_name" => step_name, "state" => state}]
      )
      when is_binary(op) and is_binary(step_name) and is_map(state) do
    [apply_step(op, step_name, normalize_args(state))]
  end

  def execute(
        _context,
        [%{"step" => "record_progress", "job_id" => job_id, "step_name" => step_name} = payload]
      )
      when is_binary(job_id) do
    result = Map.get(payload, "result", %{})

    _ =
      Jobs.progress(
        job_id,
        step_name,
        %{"status" => result["status"] || "ok", "detail" => result_detail(result)}
      )

    [%{"status" => "progressing"}]
  end

  # Multi-step ops started by hand have no job row: skip progress recording.
  def execute(
        _context,
        [%{"step" => "record_progress", "job_id" => job_id} = _payload]
      )
      when is_nil(job_id) or job_id == :null or job_id == nil do
    [%{"status" => "progressing"}]
  end

  def execute(_context, [payload]) do
    fail_non_retryable(
      "org_ops.unsupported_payload",
      "unsupported org ops activity payload: #{inspect(payload)}"
    )
  end

  # Recursively maps externalizer null atoms (:null / :nil) back to nil so
  # results stored in jsonb contain real JSON nulls.
  defp normalize_external(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {k, normalize_external(v)} end)

  defp normalize_external(value) when is_list(value),
    do: Enum.map(value, &normalize_external/1)

  defp normalize_external(:null), do: nil
  defp normalize_external(nil), do: nil
  defp normalize_external(value), do: value

  defp result_detail(%{"localpart" => lp}) when is_binary(lp), do: lp
  defp result_detail(%{"reason" => reason}), do: reason
  defp result_detail(_), do: nil

  @doc """
  Runs all steps of a (possibly multi-step) operation inline — used by the
  non-Temporal fallback path. Returns the final result map.
  """
  @spec run_all_steps(String.t(), map()) :: map()
  def run_all_steps(op, args) when is_binary(op) and is_map(args) do
    case steps_for(op) do
      [] ->
        [result] = execute(nil, [%{"step" => "apply_op", "op" => op, "args" => args}])
        result

      steps ->
        base_args = stringify(normalize_args(args))

        {ok?, facts, steps_result} =
          Enum.reduce(steps, {true, %{}, %{}}, fn
            _step, {false, facts, sr} ->
              {false, facts, sr}

            step, {true, facts, sr} ->
              [result] =
                execute(nil, [
                  %{
                    "step" => "run_step",
                    "op" => op,
                    "step_name" => step,
                    "state" => Map.merge(base_args, facts)
                  }
                ])

              sr = Map.put(sr, step, result)

              facts =
                Map.merge(
                  facts,
                  result |> Map.drop(["status", "warnings", "steps"]) |> stringify()
                )

              {result["status"] == "ok" or result["status"] == "skipped", facts, sr}
          end)

        if ok? do
          %{"status" => "ok"}
          |> Map.merge(facts)
          |> Map.put("steps", steps_result)
        else
          %{"status" => "error", "reason" => first_error(steps_result)}
          |> Map.put("steps", steps_result)
        end
    end
  end

  defp first_error(steps_result) do
    steps_result
    |> Enum.find_value(fn {step, result} ->
      if result["status"] == "error", do: "#{step}: #{result["reason"]}", else: nil
    end)
    |> case do
      nil -> "operation failed"
      reason -> reason
    end
  end

  # -- multi-step implementations -------------------------------------------

  defp apply_step("hire_agent", "ensure_department", state) do
    department = string_arg(state, "department")
    team = string_arg(state, "team")

    cond do
      department == "" ->
        %{"status" => "ok", "department" => nil, "created" => false}

      unit_exists?(department, "department") ->
        %{"status" => "ok", "department" => department, "created" => false}

      true ->
        case Org.create_unit(%{"kind" => "department", "name" => department}) do
          {:ok, _unit} ->
            %{"status" => "ok", "department" => department, "created" => true}

          {:error, _changeset} ->
            %{"status" => "ok", "department" => department, "created" => false}
        end
    end
    |> Map.merge(ensure_team(team, department))
  end

  defp apply_step("hire_agent", "create_org_record", state), do: apply_op("hire_agent", state)

  defp apply_step("hire_agent", "provision_matrix_membership", state) do
    localpart = string_arg(state, "localpart")
    rooms = state |> Map.get("rooms", []) |> List.wrap()

    cond do
      localpart == "" ->
        %{"status" => "skipped"}

      rooms == [] ->
        %{"status" => "skipped"}

      true ->
        warnings =
          Enum.flat_map(rooms, fn room_id ->
            case SynapseAdmin.invite_localpart_to_room(localpart, room_id) do
              :ok -> []
              {:error, reason} -> ["invite #{localpart} -> #{room_id} failed: #{inspect(reason)}"]
            end
          end)

        %{
          "status" => "ok",
          "joined_rooms" => length(rooms) - min(length(warnings), length(rooms)),
          "warnings" => warnings
        }
    end
  end

  defp apply_step("hire_agent", "announce_hire", state),
    do: maybe_announce(state, hire_announcement(state))

  defp apply_step("fire_agent", "deactivate_account", state), do: apply_op("fire_agent", state)

  defp apply_step("fire_agent", "cleanup_rooms", state) do
    rooms = state |> Map.get("rooms", []) |> List.wrap()

    cond do
      not truthy?(state["delete_rooms"]) or rooms == [] ->
        %{"status" => "skipped"}

      true ->
        warnings =
          Enum.flat_map(rooms, fn room_id ->
            case SynapseAdmin.delete_room(room_id) do
              :ok -> []
              {:error, reason} -> ["delete #{room_id} failed: #{inspect(reason)}"]
            end
          end)

        %{
          "status" => "ok",
          "deleted_rooms" => length(rooms) - min(length(warnings), length(rooms)),
          "warnings" => warnings
        }
    end
  end

  defp apply_step("fire_agent", "announce_departure", state),
    do: maybe_announce(state, departure_announcement(state))

  defp apply_step(_op, _step, _state), do: %{"status" => "skipped"}

  defp ensure_team(team, department) when is_binary(team) and team != "" do
    if unit_exists?(team, "team") do
      %{"team" => team, "team_created" => false}
    else
      case Org.create_unit(%{"kind" => "team", "name" => team, "department" => department}) do
        {:ok, _} -> %{"team" => team, "team_created" => true}
        _ -> %{"team" => team, "team_created" => false}
      end
    end
  end

  defp ensure_team(_, _), do: %{"team" => nil, "team_created" => false}

  defp unit_exists?(name, kind) do
    import Ecto.Query

    Repo.exists?(
      from u in SentientwaveAutomata.OrgChart.OrgUnit,
        where: u.name == ^name and u.kind == ^kind
    )
  end

  defp hire_announcement(state) do
    "#{string_arg(state, "display_name")} joined #{string_arg(state, "department")} " <>
      "as #{string_arg(state, "title")}."
  end

  defp departure_announcement(state),
    do: "#{string_arg(state, "localpart")} has left the organization."

  defp maybe_announce(state, body) do
    announce_room = string_arg(state, "announce_to")
    announce_dm = normalize_localpart(string_arg(state, "announce_localpart"))
    agent_id = state["agent_id"]

    cond do
      announce_room == "" and announce_dm == "" ->
        %{"status" => "skipped"}

      is_nil(agent_id) ->
        %{"status" => "skipped"}

      true ->
        args =
          %{"body" => body}
          |> Map.merge(if(announce_room != "", do: %{"room_id" => announce_room}, else: %{}))
          |> Map.merge(if(announce_dm != "", do: %{"to" => announce_dm}, else: %{}))

        case SendMatrixMessage.execute_direct(args, agent_id: agent_id) do
          {:ok, result} -> %{"status" => "ok"} |> Map.merge(stringify(result))
          {:error, reason} -> %{"status" => "ok", "announcement_error" => inspect(reason)}
        end
    end
  end

  defp truthy?(value), do: value in [true, "true", "TRUE", "1", 1]

  defp normalize_localpart(value), do: value |> String.trim() |> String.downcase()

  # -- operations ------------------------------------------------------------

  defp apply_op("hire_agent", args) do
    case Org.hire(args) do
      {:ok, entry} ->
        %{
          "status" => "ok",
          "hired" => true,
          "localpart" => entry.localpart,
          "matrix_user" => "@#{entry.localpart}:#{homeserver_domain()}",
          "generated_password" => Map.get(entry, :generated_password),
          "reports_to" => Map.get(entry, :reports_to)
        }

      {:error, reason} ->
        error_result(reason)
    end
  end

  defp apply_op("fire_agent", args) do
    localpart = string_arg(args, "localpart")

    case Org.fire(localpart) do
      {:ok, warnings} ->
        %{"status" => "ok", "fired" => true, "localpart" => localpart, "warnings" => warnings}

      {:error, reason} ->
        error_result(reason)
    end
  end

  defp apply_op("create_department", args), do: create_unit(args, "department")
  defp apply_op("create_team", args), do: create_unit(args, "team")

  defp apply_op("destroy_department", args) do
    destroy_unit(args, "department")
  end

  defp apply_op("destroy_team", args), do: destroy_unit(args, "team")

  defp apply_op("set_reports_to", args) do
    case Org.set_reports_to(string_arg(args, "localpart"), string_arg(args, "reports_to")) do
      {:ok, result} -> %{"status" => "ok"} |> Map.merge(normalize_keys(result))
      {:error, reason} -> error_result(reason)
    end
  end

  defp apply_op("assign_org_unit", args) do
    case Org.assign_org_unit(string_arg(args, "localpart"), args) do
      {:ok, entry} -> %{"status" => "ok"} |> Map.merge(normalize_keys(entry))
      {:error, reason} -> error_result(reason)
    end
  end

  # Matrix chat operations reuse the existing tool implementations — they are
  # plain modules over the Matrix adapter, safe to run inside an activity.
  defp apply_op("send_matrix_message", args) do
    agent_id = args["agent_id"]
    tool_args = Map.drop(args, ["agent_id"])

    run_tool(fn -> SendMatrixMessage.execute_direct(tool_args, agent_id: agent_id) end)
  end

  defp apply_op("create_matrix_room", args) do
    agent_id = args["agent_id"]
    tool_args = Map.drop(args, ["agent_id"])

    run_tool(fn -> CreateMatrixRoom.execute_direct(tool_args, agent_id: agent_id) end)
  end

  defp apply_op("delete_matrix_room", args) do
    run_tool(fn -> DeleteMatrixRoom.execute_direct(Map.drop(args, ["agent_id"]), []) end)
  end

  # Read/admin/external tools share the same durable pattern: the activity
  # reuses the tool module's direct executor so there is exactly one
  # implementation of each operation.
  defp apply_op("search_org_chart", args) do
    run_tool(fn -> OrgChartTool.execute_direct(Map.drop(args, ["agent_id", "wait"]), []) end)
  end

  defp apply_op("org_job_status", args) do
    run_tool(fn -> OrgJobStatus.execute_direct(Map.drop(args, ["agent_id", "wait"]), []) end)
  end

  defp apply_op("system_directory_admin", args) do
    run_tool(fn ->
      SystemDirectoryAdmin.execute_direct(Map.drop(args, ["agent_id", "wait"]), [])
    end)
  end

  defp apply_op("brave_search", args) do
    opts =
      [api_token: Map.get(args, "api_token", ""), base_url: Map.get(args, "base_url", "")]
      |> Keyword.reject(fn {_k, v} -> v == "" end)

    run_tool(fn ->
      BraveSearch.execute_direct(Map.drop(args, ["agent_id", "wait"]), opts)
    end)
  end

  defp apply_op("run_shell", args) do
    run_tool(fn -> RunShell.execute_direct(Map.drop(args, ["agent_id", "wait"]), []) end)
  end

  # -- helpers ---------------------------------------------------------------

  defp run_tool(fun) do
    case fun.() do
      {:ok, result} ->
        result |> stringify() |> Map.put_new("status", "ok")

      {:error, reason} ->
        error_result(reason)
    end
  end

  defp create_unit(args, kind) do
    case Org.create_unit(Map.merge(args, %{"kind" => kind})) do
      {:ok, unit} -> %{"status" => "ok", "created" => true} |> Map.merge(normalize_keys(unit))
      {:error, changeset} -> %{"status" => "error", "reason" => format_changeset(changeset)}
    end
  end

  defp destroy_unit(args, kind) do
    name = string_arg(args, "name")
    members = unit_members(name, kind)

    case Org.delete_unit(name, kind) do
      :ok ->
        warnings =
          if members == [] do
            []
          else
            [
              "#{kind} still had assigned members (left in place, now unassigned): " <>
                Enum.map_join(members, ", ", & &1.matrix_localpart)
            ]
          end

        %{
          "status" => "ok",
          "destroyed" => name != "",
          "name" => name,
          "warnings" => warnings
        }

      other ->
        error_result(other)
    end
  end

  defp unit_members(name, kind) do
    import Ecto.Query

    field = if kind == "team", do: "team", else: "department"

    Repo.all(
      from p in AgentProfile,
        where: p.status == :active,
        select: %{slug: p.slug, matrix_localpart: p.matrix_localpart, metadata: p.metadata}
    )
    |> Enum.filter(fn profile ->
      Map.get(profile.metadata || %{}, field) == name
    end)
  end

  defp error_result(reason) when is_atom(reason),
    do: %{"status" => "error", "reason" => Atom.to_string(reason)}

  defp error_result(reason), do: %{"status" => "error", "reason" => inspect(reason)}

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp normalize_keys(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp normalize_args(args) when is_map(args),
    do: args |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> Enum.sort() |> Map.new()

  # Externalizer null artifacts (:null atom, "nil"/"null" strings) count as
  # empty — see OrgChart.presence/1 for the full story.
  defp string_arg(args, key) do
    case Map.get(args, key) do
      nil -> ""
      :null -> ""
      "nil" -> ""
      "null" -> ""
      value -> value |> to_string() |> String.trim()
    end
  end

  defp homeserver_domain, do: System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")

  defp format_changeset(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
    |> Enum.map_join(", ", fn {field, messages} ->
      "#{field}: #{messages |> List.wrap() |> Enum.join(",")}"
    end)
  end

  defp fail_non_retryable(type, message) do
    fail(message: message, type: type, non_retryable: true)
  end
end
