defmodule DashboardPhoenix.Repo do
  @moduledoc """
  Database repository for the dashboard application.

  Provides database access and query capabilities using Ecto with PostgreSQL.
  """
  use Ecto.Repo,
    otp_app: :dashboard_phoenix,
    adapter: Ecto.Adapters.Postgres
end
