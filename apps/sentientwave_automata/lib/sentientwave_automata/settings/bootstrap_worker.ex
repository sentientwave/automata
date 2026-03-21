defmodule SentientwaveAutomata.Settings.BootstrapWorker do
  @moduledoc false
  use GenServer

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Settings

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def init(state) do
    Process.send_after(self(), :bootstrap, 1_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    Directory.seed_from_env()
    maybe_seed_llm_provider()
    maybe_seed_tools()
    maybe_grant_automata_privileged_tools()
    {:noreply, state}
  end

  defp maybe_seed_llm_provider do
    Settings.ensure_default_provider_from_env()
  end

  defp maybe_seed_tools do
    Settings.ensure_default_tools_from_env()
  end

  defp maybe_grant_automata_privileged_tools do
    localpart =
      System.get_env("MATRIX_AGENT_USER", "automata")
      |> to_string()
      |> String.trim()
      |> String.downcase()

    with {:ok, agent} <-
           Agents.upsert_agent(%{
             slug: localpart,
             kind: :agent,
             display_name: "Agent #{localpart}",
             matrix_localpart: localpart,
             status: :active,
             metadata: %{source: "bootstrap_worker"}
           }) do
      _ =
        Agents.upsert_agent_wallet(agent.id, %{
          kind: "personal",
          status: "active",
          matrix_credentials: %{
            localpart: localpart,
            mxid: "@#{localpart}:#{System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")}",
            password: System.get_env("MATRIX_AGENT_PASSWORD", ""),
            homeserver_url: System.get_env("MATRIX_URL", "http://localhost:8008")
          },
          metadata: %{source: "bootstrap_worker"}
        })

      _ =
        grant_tool(agent.id, "system_directory_admin", %{
          "level" => "system"
        })

      _ =
        grant_tool(agent.id, "run_shell", %{
          "level" => "system",
          "mode" => "arbitrary_command"
        })

      :ok
    else
      _ -> :ok
    end
  end

  defp grant_tool(agent_id, tool_name, constraints) do
    Agents.set_tool_permission(%{
      agent_id: agent_id,
      tool_name: tool_name,
      scope: "default",
      allowed: true,
      constraints: constraints
    })
  end
end
