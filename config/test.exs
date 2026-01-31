import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :dashboard_phoenix, DashboardPhoenix.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "dashboard_phoenix_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Run server during test so tests can hit the actual endpoint
config :dashboard_phoenix, DashboardPhoenixWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4002")],
  secret_key_base: "GtYCddWWsPjCOACgHDjkKw04+pHhnJj/9tdtedR/O65jq8gK4BL1D/FElGGEyqHh",
  server: true

# In test we don't send emails
config :dashboard_phoenix, DashboardPhoenix.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
