defmodule SentientwaveAutomata.Repo do
  use Ecto.Repo,
    otp_app: :sentientwave_automata,
    adapter: Ecto.Adapters.Postgres
end
