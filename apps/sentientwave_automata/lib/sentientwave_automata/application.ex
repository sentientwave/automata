defmodule SentientwaveAutomata.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SentientwaveAutomata.Repo,
      {DNSCluster,
       query: Application.get_env(:sentientwave_automata, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SentientwaveAutomata.PubSub},
      SentientwaveAutomata.Matrix.Directory,
      SentientwaveAutomata.Matrix.ReconciliationWorker,
      SentientwaveAutomata.Matrix.MentionPoller,
      SentientwaveAutomata.Orchestration.Store,
      SentientwaveAutomata.Settings.BootstrapWorker,
      SentientwaveAutomata.Licensing.SeatManager
      # Start a worker by calling: SentientwaveAutomata.Worker.start_link(arg)
      # {SentientwaveAutomata.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SentientwaveAutomata.Supervisor)
  end
end
