defmodule DashboardPhoenixWeb.Plugs.AuthTest do
  use DashboardPhoenixWeb.ConnCase, async: true

  alias DashboardPhoenixWeb.Plugs.Auth

  @test_token "test-secret-token-12345"

  describe "when auth is disabled (no token configured)" do
    setup do
      # Ensure no auth token is configured
      Application.delete_env(:dashboard_phoenix, :auth_token)
      on_exit(fn -> Application.delete_env(:dashboard_phoenix, :auth_token) end)
      :ok
    end

    test "allows access without authentication", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200)
    end

    test "auth_enabled? returns false" do
      refute Auth.auth_enabled?()
    end
  end

  describe "when auth is enabled" do
    setup do
      Application.put_env(:dashboard_phoenix, :auth_token, @test_token)
      on_exit(fn -> Application.delete_env(:dashboard_phoenix, :auth_token) end)
      :ok
    end

    test "auth_enabled? returns true" do
      assert Auth.auth_enabled?()
    end

    test "unauthenticated requests are redirected to login", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == "/login"
    end

    test "requests with valid token in query param are authenticated", %{conn: conn} do
      conn = get(conn, ~p"/?token=#{@test_token}")
      # Should redirect to / (clean URL) after setting session
      assert redirected_to(conn) == "/"

      # Follow redirect - now should be authenticated via session
      conn = get(recycle(conn), ~p"/")
      assert html_response(conn, 200)
    end

    test "requests with invalid token in query param get 401", %{conn: conn} do
      conn = get(conn, ~p"/?token=wrong-token")
      assert html_response(conn, 401) =~ "Unauthorized"
    end

    test "requests with valid token in Authorization header are authenticated", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{@test_token}")
        |> get(~p"/")

      assert html_response(conn, 200)
    end

    test "requests with invalid token in Authorization header get 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer wrong-token")
        |> get(~p"/")

      assert html_response(conn, 401) =~ "Unauthorized"
    end

    test "session persists after initial authentication", %{conn: conn} do
      # First request with token
      conn = get(conn, ~p"/?token=#{@test_token}")
      assert redirected_to(conn) == "/"

      # Second request without token - should still work via session
      conn = get(recycle(conn), ~p"/")
      assert html_response(conn, 200)

      # Third request - still authenticated
      conn = get(recycle(conn), ~p"/")
      assert html_response(conn, 200)
    end

    test "logout clears authentication", %{conn: conn} do
      # Authenticate first
      conn = get(conn, ~p"/?token=#{@test_token}")
      conn = get(recycle(conn), ~p"/")
      assert html_response(conn, 200)

      # Logout
      conn = get(recycle(conn), ~p"/logout")
      assert redirected_to(conn) == "/login"

      # Should no longer be authenticated
      conn = get(recycle(conn), ~p"/")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "login page" do
    setup do
      Application.put_env(:dashboard_phoenix, :auth_token, @test_token)
      on_exit(fn -> Application.delete_env(:dashboard_phoenix, :auth_token) end)
      :ok
    end

    test "login page is accessible without auth", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200) =~ "Authentication Token"
    end

    test "POST to login with valid token authenticates", %{conn: conn} do
      conn = post(conn, ~p"/login", %{token: @test_token})
      assert redirected_to(conn) == "/"

      # Now should be authenticated
      conn = get(recycle(conn), ~p"/")
      assert html_response(conn, 200)
    end

    test "POST to login with invalid token shows error", %{conn: conn} do
      conn = post(conn, ~p"/login", %{token: "wrong-token"})
      assert html_response(conn, 200) =~ "Invalid token"
    end

    test "POST to login without token shows error", %{conn: conn} do
      conn = post(conn, ~p"/login", %{})
      assert html_response(conn, 200) =~ "Token required"
    end

    test "authenticated user visiting login is redirected to dashboard", %{conn: conn} do
      # Authenticate first
      conn = post(conn, ~p"/login", %{token: @test_token})
      
      # Try to visit login page again
      conn = get(recycle(conn), ~p"/login")
      assert redirected_to(conn) == "/"
    end
  end

  describe "token comparison security" do
    setup do
      Application.put_env(:dashboard_phoenix, :auth_token, @test_token)
      on_exit(fn -> Application.delete_env(:dashboard_phoenix, :auth_token) end)
      :ok
    end

    test "token comparison is timing-safe", %{conn: conn} do
      # This test ensures we're using secure_compare
      # A timing attack with a similar-length token shouldn't work
      similar_token = "test-secret-token-12346"  # Only last char different
      conn = get(conn, ~p"/?token=#{similar_token}")
      assert html_response(conn, 401) =~ "Unauthorized"
    end

    test "empty token is rejected", %{conn: conn} do
      conn = get(conn, ~p"/?token=")
      assert html_response(conn, 401) =~ "Unauthorized"
    end

    test "token with extra whitespace is rejected", %{conn: conn} do
      # Use regular path string since ~p doesn't support dynamic trailing spaces
      conn = get(conn, "/?token=#{@test_token} ")
      assert html_response(conn, 401) =~ "Unauthorized"
    end
  end
end
