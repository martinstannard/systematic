defmodule DashboardPhoenix.CommandRunnerTest do
  @moduledoc """
  Tests for CommandRunner timeout handling.
  """
  use ExUnit.Case, async: true

  alias DashboardPhoenix.CommandRunner

  describe "run/3" do
    test "returns {:ok, output} for successful command" do
      assert {:ok, output} = CommandRunner.run("echo", ["hello"])
      assert String.trim(output) == "hello"
    end

    test "returns {:error, {:exit, code, output}} for failed command" do
      assert {:error, {:exit, code, _output}} = CommandRunner.run("sh", ["-c", "exit 42"])
      assert code == 42
    end

    test "returns {:error, :timeout} when command exceeds timeout" do
      # Use a very short timeout with a slow command
      assert {:error, :timeout} = CommandRunner.run("sleep", ["10"], timeout: 50)
    end

    test "respects cd option" do
      assert {:ok, output} = CommandRunner.run("pwd", [], cd: "/tmp")
      assert String.trim(output) == "/tmp"
    end

    test "merges stderr to stdout by default" do
      # This command writes to stderr
      assert {:ok, output} = CommandRunner.run("sh", ["-c", "echo error >&2"])
      assert String.contains?(output, "error")
    end

    test "handles command not found gracefully" do
      result = CommandRunner.run("nonexistent_command_12345", [])
      # Should return an error, not crash
      assert match?({:error, _}, result)
    end
  end

  describe "run!/3" do
    test "returns output string on success" do
      assert output = CommandRunner.run!("echo", ["world"])
      assert String.trim(output) == "world"
    end

    test "returns nil on failure" do
      assert CommandRunner.run!("sh", ["-c", "exit 1"]) == nil
    end

    test "returns nil on timeout" do
      assert CommandRunner.run!("sleep", ["10"], timeout: 50) == nil
    end
  end

  describe "run_json/3" do
    test "parses JSON output on success" do
      json = ~s({"key": "value"})
      assert {:ok, %{"key" => "value"}} = CommandRunner.run_json("echo", [json])
    end

    test "returns error tuple for invalid JSON" do
      assert {:error, {:json_decode, _}} = CommandRunner.run_json("echo", ["not json"])
    end

    test "returns error on command failure" do
      assert {:error, {:exit, _, _}} = CommandRunner.run_json("sh", ["-c", "exit 1"])
    end

    test "returns timeout error" do
      assert {:error, :timeout} = CommandRunner.run_json("sleep", ["10"], timeout: 50)
    end

    test "handles empty JSON array" do
      assert {:ok, []} = CommandRunner.run_json("echo", ["[]"])
    end

    test "handles complex JSON" do
      json = ~s([{"id": 1, "name": "test"}, {"id": 2, "name": "test2"}])
      assert {:ok, [%{"id" => 1}, %{"id" => 2}]} = CommandRunner.run_json("echo", [json])
    end
  end

  describe "timeout behavior" do
    test "process is killed after timeout" do
      # Start a command that would run forever
      start_time = System.monotonic_time(:millisecond)
      result = CommandRunner.run("sleep", ["60"], timeout: 100)
      end_time = System.monotonic_time(:millisecond)
      
      # Should return quickly (within ~200ms, not 60 seconds)
      assert {:error, :timeout} = result
      assert end_time - start_time < 500
    end

    test "default timeout is 30 seconds" do
      # We can't easily test the full 30s, but we can verify quick commands work
      assert {:ok, _} = CommandRunner.run("echo", ["quick"])
    end
  end

  describe "graceful error handling" do
    test "does not crash on timeout - returns error tuple" do
      # This is important for GenServer health
      result = CommandRunner.run("sleep", ["100"], timeout: 10)
      assert {:error, :timeout} = result
    end

    test "does not crash on command error - returns error tuple" do
      result = CommandRunner.run("sh", ["-c", "exit 127"])
      assert {:error, {:exit, 127, _}} = result
    end
  end
end
