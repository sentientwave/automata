defmodule SentientwaveAutomata.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SentientwaveAutomata.Repo,
        {DNSCluster,
         query: Application.get_env(:sentientwave_automata, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: SentientwaveAutomata.PubSub}
      ] ++
        background_children() ++
        [
          SentientwaveAutomata.Orchestration.Store,
          SentientwaveAutomata.Licensing.SeatManager
          # Start a worker by calling: SentientwaveAutomata.Worker, arg
          # {SentientwaveAutomata.Worker, arg}
        ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SentientwaveAutomata.Supervisor)
  end

  defp background_children do
    if Application.get_env(:sentientwave_automata, :background_workers_enabled, true) do
      [
        SentientwaveAutomata.Matrix.ReconciliationWorker,
        SentientwaveAutomata.Matrix.MentionPoller,
        SentientwaveAutomata.Governance.ProposalResolutionWorker,
        SentientwaveAutomata.Agents.ScheduledTaskWorker,
        SentientwaveAutomata.Settings.BootstrapWorker
      ]
    else
      []
    end
  end
end
