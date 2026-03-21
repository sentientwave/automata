# This file is responsible for configuring your umbrella
# and **all applications** and their dependencies with the
# help of the Config module.
#
# Note that all applications in your umbrella share the
# same configuration and dependencies, which is why they
# all use the same configuration file. If you want different
# configurations or dependencies per app, it is best to
# move said applications out of the umbrella.
import Config

# Configure Mix tasks and generators
config :sentientwave_automata,
  ecto_repos: [SentientwaveAutomata.Repo],
  edition: :community,
  matrix_adapter: SentientwaveAutomata.Adapters.Matrix.Local,
  temporal_adapter: SentientwaveAutomata.Adapters.Temporal.Local,
  temporal_bridge_url: "http://localhost:8099",
  embedding_provider: SentientwaveAutomata.Agents.Embedding.Local,
  embedding_dim: 64,
  agent_skills_path: "skills",
  temporal_agent_task_queue: "automata-agents"

config :sentientwave_automata_web,
  ecto_repos: [SentientwaveAutomata.Repo],
  generators: [context_app: :sentientwave_automata]

# Configures the endpoint
config :sentientwave_automata_web, SentientwaveAutomataWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SentientwaveAutomataWeb.ErrorHTML, json: SentientwaveAutomataWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: SentientwaveAutomata.PubSub,
  live_view: [signing_salt: "a6mpeZGH"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  sentientwave_automata_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../apps/sentientwave_automata_web/assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  sentientwave_automata_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("../apps/sentientwave_automata_web", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
