defmodule DashboardPhoenixWeb.AuthController do
  @moduledoc """
  Handles authentication and authorization for the dashboard.

  Provides login, logout, and token-based authentication functionality.
  Supports secure token comparison and session management.
  """
  use DashboardPhoenixWeb, :controller

  alias DashboardPhoenixWeb.Plugs.Auth

  def login(conn, _params) do
    if get_session(conn, :authenticated) do
      redirect(conn, to: ~p"/")
    else
      render(conn, :login, error: nil)
    end
  end

  def authenticate(conn, %{"token" => token}) do
    case Auth.get_auth_token() do
      nil ->
        # Auth disabled, just redirect
        redirect(conn, to: ~p"/")

      configured_token ->
        if Plug.Crypto.secure_compare(token, configured_token) do
          conn
          |> put_session(:authenticated, true)
          |> redirect(to: ~p"/")
        else
          render(conn, :login, error: "Invalid token")
        end
    end
  end

  def authenticate(conn, _params) do
    render(conn, :login, error: "Token required")
  end

  def logout(conn, _params) do
    conn
    |> Auth.logout()
    |> redirect(to: ~p"/login")
  end
end
