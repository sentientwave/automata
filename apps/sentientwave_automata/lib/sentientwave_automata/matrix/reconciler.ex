defmodule SentientwaveAutomata.Matrix.Reconciler do
  @moduledoc """
  Reconciles internal directory users with Matrix homeserver users.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.SynapseAdmin

  @spec reconcile() :: map()
  def reconcile do
    users =
      Directory.list_users()
      |> Kernel.++(persisted_agent_users())
      |> Enum.uniq_by(& &1.localpart)

    result =
      Enum.reduce(users, %{ok: [], failed: []}, fn user, acc ->
        case SynapseAdmin.reconcile_user(user) do
          :ok ->
            %{acc | ok: [user.localpart | acc.ok]}

          {:error, reason} ->
            %{acc | failed: [%{localpart: user.localpart, reason: inspect(reason)} | acc.failed]}
        end
      end)
      |> reconcile_operator_invites()

    result
    |> then(fn result ->
      %{result | ok: Enum.reverse(result.ok), failed: Enum.reverse(result.failed)}
    end)
  end

  defp reconcile_operator_invites(result) do
    case SynapseAdmin.reconcile_operator_invites() do
      :ok ->
        result

      {:error, reason} ->
        %{result | failed: [%{localpart: "automata", reason: inspect(reason)} | result.failed]}
    end
  end

  defp persisted_agent_users do
    Agents.list_active_agents()
    |> Enum.filter(&(&1.kind == :agent))
    |> Enum.flat_map(fn agent ->
      case Agents.get_agent_wallet(agent.id) do
        %{matrix_credentials: %{"password" => password}}
        when is_binary(password) and password != "" ->
          [
            %{
              id: "agent:#{agent.matrix_localpart}",
              localpart: agent.matrix_localpart,
              kind: :agent,
              display_name: agent.display_name || "Agent #{agent.matrix_localpart}",
              password: password,
              admin: false
            }
          ]

        %{matrix_credentials: %{password: password}}
        when is_binary(password) and password != "" ->
          [
            %{
              id: "agent:#{agent.matrix_localpart}",
              localpart: agent.matrix_localpart,
              kind: :agent,
              display_name: agent.display_name || "Agent #{agent.matrix_localpart}",
              password: password,
              admin: false
            }
          ]

        _ ->
          []
      end
    end)
  end
end
