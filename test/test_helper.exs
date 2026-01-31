# Load mocks before ExUnit starts
Code.require_file("support/mocks.ex", __DIR__)

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(DashboardPhoenix.Repo, :manual)
