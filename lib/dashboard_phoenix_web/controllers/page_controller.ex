defmodule DashboardPhoenixWeb.PageController do
  use DashboardPhoenixWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
