defmodule SentientwaveAutomata.OrgChart.Consistency do
  @moduledoc """
  Cross-store consistency guarantees for org operations.

  Three layers, by design:
  1. Per-operation verification: every mutating OpsWorkflow ends with a
     `verify_entity` check across directory / agent profiles / Matrix, and
     HEALS drift before the workflow can complete.
  2. Fleet-wide reconciliation: `reconcile/0` scans ALL stores, heals drift,
     and is invoked periodically from the Temporal bootstrap loop.
  3. Single mutation path: all org/chat mutations run through
     OrgChart.OpsWorkflow, so the guarantees above always apply.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.SynapseAdmin
  alias SentientwaveAutomata.Repo

  require Logger

  @min_reconcile_interval_ms :timer.minutes(10)

  # -- expected-state computation ---------------------------------------------

  @doc "Localparts that must ALWAYS have an active Matrix account."
  def exempt_localparts do
    service =
      ["admin", System.get_env("MATRIX_AGENT_USER", ""), System.get_env("MATRIX_READER_USER", "")]
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    env_locals =
      ["AUTOMATA_ORG_PRINCIPAL_LOCALPARTS", "AUTOMATA_ORG_EXECUTIVE_LOCALPARTS"]
      |> Enum.flat_map(&String.split(System.get_env(&1, ""), ","))
      |> Enum.map(&normalize_localpart/1)
      |> Enum.reject(&(&1 == ""))

    MapSet.new(service ++ env_locals)
  end

  @doc "Localparts that should currently have an active Matrix account."
  def expected_active_localparts do
    directory = Directory.list_users()
    # DirectoryUser.kind is an Ecto.Enum loaded as atoms (:person); accept both.
    persons =
      directory
      |> Enum.filter(&(&1.kind in [:person, "person"]))
      |> Enum.map(& &1.localpart)

    active_agents = active_agent_localparts()

    (persons ++ active_agents)
    |> MapSet.new()
    |> MapSet.union(exempt_localparts())
  end

  defp active_agent_localparts do
    import Ecto.Query

    Repo.all(
      from a in SentientwaveAutomata.Agents.AgentProfile,
        where: a.kind == :agent and a.status == :active,
        select: coalesce(a.matrix_localpart, a.slug)
    )
  end

  @doc """
  Pure diff between the Matrix-active set and the expected-active set.
  Returns stray accounts (active in Matrix but not expected) and missing
  accounts (expected but not active).
  """
  def diff(matrix_active_localparts, expected_localparts) do
    matrix = MapSet.new(matrix_active_localparts)
    expected = MapSet.new(expected_localparts)

    %{
      strays: MapSet.to_list(MapSet.difference(matrix, expected)),
      missing: MapSet.to_list(MapSet.difference(expected, matrix))
    }
  end

  # -- fleet-wide reconciliation -----------------------------------------------

  @doc """
  Audits all stores and heals drift. Throttled to once per
  @min_reconcile_interval_ms; safe to call from a fast loop.
  """
  def reconcile(opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    if force? or reconcile_due?() do
      report = do_reconcile()
      {:ok, report}
    else
      :throttled
    end
  end

  defp reconcile_due? do
    key = {__MODULE__, :last_reconcile}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      %{at: at} when now - at < @min_reconcile_interval_ms ->
        false

      _ ->
        :persistent_term.put(key, %{at: now})
        true
    end
  end

  defp do_reconcile do
    case SynapseAdmin.list_active_users() do
      {:ok, matrix_active} ->
        reconcile_with_users(matrix_active)

      {:error, reason} ->
        Logger.warning("consistency_list_users_failed reason=#{inspect(reason)}")
        %{"status" => "error", "reason" => inspect(reason)}
    end
  end

  defp reconcile_with_users(matrix_active) do
    expected = MapSet.to_list(expected_active_localparts())

    %{strays: strays, missing: missing} = diff(matrix_active, expected)

    healed_strays =
      Enum.map(strays, fn lp ->
        case SynapseAdmin.deactivate_user(lp) do
          :ok -> Logger.warning("consistency_heal deactivated stray matrix account #{lp}")
          _ -> Logger.warning("consistency_heal FAILED to deactivate #{lp}")
        end

        lp
      end)

    healed_missing =
      missing
      |> Enum.map(fn lp ->
        directory_user = Directory.get_user_with_password(lp)
        kind = directory_user && Map.get(directory_user, :kind)

        cond do
          match?(%{status: :active}, Agents.get_agent_by_localpart(lp)) and
            kind in [:agent, "agent"] and is_map(directory_user) ->
            case SynapseAdmin.reconcile_user(directory_user) do
              :ok ->
                Logger.warning("consistency_heal re-provisioned matrix account #{lp}")
                %{localpart: lp, outcome: "re-provisioned"}

              {:error, reason} ->
                Logger.warning(
                  "consistency_heal FAILED to re-provision #{lp}: #{inspect(reason)}"
                )

                %{localpart: lp, outcome: "re-provision failed"}
            end

          kind in ["person", :person] ->
            # Persons (org principals): reactivate with a fresh password.
            case SynapseAdmin.reactivate_user(lp) do
              {:ok, password} ->
                Logger.warning("consistency_heal reactivated person account #{lp}")

                %{
                  "localpart" => lp,
                  "outcome" => "reactivated",
                  "new_password" => password
                }

              {:error, reason} ->
                %{localpart: lp, outcome: "reactivation failed: #{inspect(reason)}"}
            end

          true ->
            %{localpart: lp, outcome: "no healing rule for this account"}
        end
      end)

    %{
      "matrix_active" => length(matrix_active),
      "expected_active" => length(expected),
      "healed_strays" => healed_strays,
      "healed_missing" => healed_missing,
      "drift_found?" => strays != [] or missing != []
    }
  rescue
    e ->
      Logger.warning("consistency_reconcile_failed error=#{Exception.message(e)}")
      %{"status" => "error", "reason" => Exception.message(e)}
  end

  # -- per-operation verification ----------------------------------------------

  @doc """
  Verifies one localpart against the expectation ("present" after hire,
  "absent" after fire), healing drift so the operation converges. Returns a
  map with per-store state; raises nothing — drift that cannot be healed is
  reported in the result.
  """
  def verify_entity("present", localpart), do: verify_present(localpart)
  def verify_entity("absent", localpart), do: verify_absent(localpart)

  def verify_entity(expectation, _localpart),
    do: %{"expectation" => expectation, "verified" => false, "reason" => "unknown_expectation"}

  defp verify_present(localpart) do
    directory_ok? = Directory.get_user(localpart) != nil
    profile_ok? = match?(%{status: :active}, Agents.get_agent_by_localpart(localpart))
    matrix_active? = SynapseAdmin.user_active?(localpart)

    healed =
      if directory_ok? and profile_ok? and not matrix_active? do
        case Directory.get_user_with_password(localpart) do
          %{kind: kind} = user when kind in [:agent, "agent"] ->
            match?(:ok, SynapseAdmin.reconcile_user(user))

          _ ->
            false
        end
      else
        false
      end

    matrix_active? = matrix_active? or healed

    %{
      "expectation" => "present",
      "directory" => directory_ok?,
      "agent_profile" => profile_ok?,
      "matrix" => matrix_active?,
      "verified" => directory_ok? and profile_ok? and matrix_active?,
      "healed" => healed
    }
  end

  defp verify_absent(localpart) do
    directory_gone? = Directory.get_user(localpart) == nil

    profile_disabled? =
      case Agents.get_agent_by_localpart(localpart) do
        nil -> true
        %{status: status} -> status != :active
      end

    matrix_gone_or_inactive? = not SynapseAdmin.user_active?(localpart)

    healed =
      if not matrix_gone_or_inactive? do
        match?(:ok, SynapseAdmin.deactivate_user(localpart))
      else
        false
      end

    matrix_gone_or_inactive? = matrix_gone_or_inactive? or healed

    %{
      "expectation" => "absent",
      "directory_removed" => directory_gone?,
      "agent_profile_disabled" => profile_disabled?,
      "matrix_deactivated" => matrix_gone_or_inactive?,
      "verified" => directory_gone? and profile_disabled? and matrix_gone_or_inactive?,
      "healed" => healed
    }
  end

  defp normalize_localpart(value), do: value |> to_string() |> String.trim() |> String.downcase()
end
