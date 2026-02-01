defmodule DashboardPhoenix.WorkSpawnerTest do
  use ExUnit.Case, async: true
  
  alias DashboardPhoenix.WorkSpawner

  describe "format_spawn_error/2" do
    test "formats connection refused error" do
      result = WorkSpawner.format_spawn_error(:claude, {:error, :econnrefused})
      assert result =~ "[connection_error]"
      assert result =~ "Claude server not reachable"
      assert result =~ "Connection refused"
    end

    test "formats timeout error" do
      result = WorkSpawner.format_spawn_error(:opencode, {:error, :timeout})
      assert result =~ "[timeout]"
      assert result =~ "OpenCode timed out"
    end

    test "formats rate limit error" do
      result = WorkSpawner.format_spawn_error(:claude, {:error, %{status: 429}})
      assert result =~ "[rate_limit]"
      assert result =~ "Rate limited"
    end

    test "formats server error" do
      result = WorkSpawner.format_spawn_error(:gemini, {:error, %{status: 500}})
      assert result =~ "[server_error]"
      assert result =~ "Gemini server error"
    end

    test "formats auth error" do
      result = WorkSpawner.format_spawn_error(:claude, {:error, %{status: 401}})
      assert result =~ "[auth_error]"
      assert result =~ "Authentication failed"
    end

    test "formats unknown agent type error" do
      result = WorkSpawner.format_spawn_error(:unknown, "Unknown agent type: fake")
      assert result =~ "[invalid_config]"
      assert result =~ "Unknown agent type"
    end

    test "formats generic errors" do
      result = WorkSpawner.format_spawn_error(:claude, {:error, "Something went wrong"})
      assert result =~ "[spawn_failed]"
      assert result =~ "Something went wrong"
    end

    test "truncates long error messages" do
      long_message = String.duplicate("x", 200)
      result = WorkSpawner.format_spawn_error(:claude, {:error, long_message})
      # Should truncate to ~100 chars + "..."
      refute result =~ String.duplicate("x", 150)
      assert result =~ "..."
    end
  end
end
