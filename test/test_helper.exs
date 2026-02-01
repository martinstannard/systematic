# Mocks are automatically compiled via elixirc_paths in mix.exs
# No need to Code.require_file them (causes redefinition warnings)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(DashboardPhoenix.Repo, :manual)
