defmodule DashboardPhoenix.ProcessCwdTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.ProcessCwd

  describe "get/1" do
    test "returns cwd for current process" do
      # Self PID should always work
      pid = System.pid() |> String.to_integer()
      
      case ProcessCwd.get(pid) do
        {:ok, cwd} ->
          assert is_binary(cwd)
          assert String.length(cwd) > 0
          # Should be an absolute path
          assert String.starts_with?(cwd, "/")
        
        {:error, :unsupported} ->
          # Skip on unsupported platforms
          :ok
      end
    end

    test "handles string pid" do
      pid = System.pid()
      
      case ProcessCwd.get(pid) do
        {:ok, cwd} ->
          assert is_binary(cwd)
        
        {:error, :unsupported} ->
          :ok
      end
    end

    test "returns error for non-existent process" do
      # Use a very high PID that's unlikely to exist
      result = ProcessCwd.get(999_999_999)
      
      assert result == {:error, :not_found} or result == {:error, :unsupported}
    end

    test "returns error for invalid string pid" do
      assert ProcessCwd.get("not-a-number") == {:error, :not_found}
    end
  end

  describe "get!/1" do
    test "returns cwd string or nil for current process" do
      pid = System.pid() |> String.to_integer()
      result = ProcessCwd.get!(pid)
      
      # Either returns a path or nil (on unsupported platforms)
      assert is_nil(result) or (is_binary(result) and String.starts_with?(result, "/"))
    end

    test "returns nil for non-existent process" do
      assert ProcessCwd.get!(999_999_999) == nil
    end

    test "returns nil for invalid pid" do
      assert ProcessCwd.get!("invalid") == nil
    end
  end
end
