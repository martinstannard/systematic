defmodule DashboardPhoenixWeb.PageController do
  @moduledoc """
  Handles static page requests for the dashboard application.

  Provides basic page rendering functionality, including the home page.
  """
  use DashboardPhoenixWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
