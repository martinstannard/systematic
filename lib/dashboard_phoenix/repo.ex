defmodule DashboardPhoenix.Repo do
  use Ecto.Repo,
    otp_app: :dashboard_phoenix,
    adapter: Ecto.Adapters.Postgres
end
