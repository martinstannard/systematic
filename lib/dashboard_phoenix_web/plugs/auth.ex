defmodule DashboardPhoenixWeb.Plugs.Auth do
  @moduledoc """
  Authentication plug for the dashboard.

  Supports token-based authentication via:
  - Query parameter: `?token=xxx`
  - Authorization header: `Authorization: Bearer xxx`
  - Session cookie (after initial auth)

  When `DASHBOARD_AUTH_TOKEN` is not set, authentication is disabled
  (useful for dev/localhost mode).
  """

  import Plug.Conn
  import Phoenix.Controller

  @behaviour Plug

  @session_key :authenticated
  @token_session_key :auth_token

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    token = get_auth_token()
    # IO.inspect(token, label: "AUTH TOKEN")
    case token do
      nil ->
        # No token configured - auth disabled
        conn

      configured_token ->
        authenticate(conn, configured_token)
    end
  end

  defp authenticate(conn, configured_token) do
    cond do
      # Already authenticated via session
      get_session(conn, @session_key) == true ->
        conn

      # Token in query params
      token = conn.query_params["token"] ->
        verify_and_auth(conn, token, configured_token)

      # Token in Authorization header
      token = get_bearer_token(conn) ->
        verify_and_auth(conn, token, configured_token)

      # Not authenticated - redirect to login
      true ->
        conn
        |> redirect(to: "/login")
        |> halt()
    end
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp verify_and_auth(conn, provided_token, configured_token) do
    if Plug.Crypto.secure_compare(provided_token, configured_token) do
      conn
      |> put_session(@session_key, true)
      |> put_session(@token_session_key, provided_token)
      |> redirect_to_dashboard()
    else
      conn
      |> put_status(:unauthorized)
      |> put_view(DashboardPhoenixWeb.ErrorHTML)
      |> render("401.html")
      |> halt()
    end
  end

  defp redirect_to_dashboard(conn) do
    # If we came from a query param, redirect to clean URL
    if conn.query_params["token"] do
      conn
      |> redirect(to: "/")
      |> halt()
    else
      conn
    end
  end

  @doc """
  Returns the configured auth token from application config.
  Returns nil if not configured (auth disabled).
  """
  def get_auth_token do
    Application.get_env(:dashboard_phoenix, :auth_token)
  end

  @doc """
  Checks if authentication is enabled.
  """
  def auth_enabled? do
    get_auth_token() != nil
  end

  @doc """
  Logs out the current session.
  """
  def logout(conn) do
    conn
    |> delete_session(@session_key)
    |> delete_session(@token_session_key)
  end
end
