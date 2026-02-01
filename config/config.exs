# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dashboard_phoenix,
  ecto_repos: [DashboardPhoenix.Repo],
  generators: [timestamp_type: :utc_datetime]

# Path configuration - defaults are set in Paths module, can be overridden by environment variables
# Setting these to nil keeps the defaults from the Paths module
# Uncomment and set values to override specific paths
# config :dashboard_phoenix,
#   openclaw_home: "/custom/openclaw/path",
#   openclaw_sessions_dir: "/custom/sessions/path", 
#   opencode_storage_dir: "/custom/opencode/storage",
#   session_update_script: "/custom/scripts/update_sessions.sh"

# Configures the endpoint
config :dashboard_phoenix, DashboardPhoenixWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: DashboardPhoenixWeb.ErrorHTML, json: DashboardPhoenixWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: DashboardPhoenix.PubSub,
  live_view: [signing_salt: "ogUw93um"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :dashboard_phoenix, DashboardPhoenix.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  dashboard_phoenix: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.7",
  dashboard_phoenix: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
