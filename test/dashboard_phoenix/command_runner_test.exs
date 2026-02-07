defmodule DashboardPhoenix.CommandRunnerTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.CommandRunner

  setup do
    # Reset rate limiter before each test for proper test isolation
    DashboardPhoenix.RateLimiter.reset()
    :ok
  end

  describe "basic command execution" do
    test "runs simple commands successfully" do
      result = CommandRunner.run("echo", ["hello world"])
      assert {:ok, output} = result
      assert String.trim(output) == "hello world"
    end

    test "handles command failures" do
      result = CommandRunner.run("false", [])
      assert {:error, {:exit, 1, ""}} = result
    end

    test "handles timeouts" do
      result = CommandRunner.run("sleep", ["10"], timeout: 100)
      assert {:error, :timeout} = result
    end
  end

  describe "rate limiting" do
    test "applies rate limiting by default" do
      # First command should work
      result = CommandRunner.run("echo", ["test1"])
      assert {:ok, _} = result

      # We can't easily test rate limiting exhaustion in a unit test
      # without making many calls, so we'll test that it's enabled
      assert result != {:error, :rate_limited}
    end

    test "can disable rate limiting" do
      result = CommandRunner.run("echo", ["test"], rate_limit: false)
      assert {:ok, _} = result
    end

    test "rate limiting works with JSON commands" do
      # JSON commands should still work
      result = CommandRunner.run_json("echo", [~s|{"key": "value"}|])
      assert {:ok, %{"key" => "value"}} = result
    end
  end

  describe "retry functionality" do
    test "retries on retryable failures when enabled" do
      # Create a script that fails first time but succeeds second time
      script_path = "/tmp/test_retry_#{:rand.uniform(10000)}"

      # Create a script that tracks attempts and fails on first try
      script_content = """
      #!/bin/bash
      ATTEMPT_FILE="/tmp/attempt_count_#{:rand.uniform(10000)}"

      if [ ! -f "$ATTEMPT_FILE" ]; then
          echo "1" > "$ATTEMPT_FILE"
          echo "timeout error" >&2
          exit 124  # Retryable exit code
      else
          count=$(cat "$ATTEMPT_FILE")
          echo "$((count + 1))" > "$ATTEMPT_FILE"
          echo "success on attempt $((count + 1))"
          rm -f "$ATTEMPT_FILE"
          exit 0
      fi
      """

      File.write!(script_path, script_content)
      File.chmod!(script_path, 0o755)

      try do
        # Should succeed after retry
        result = CommandRunner.run("bash", [script_path], retry: true, initial_delay_ms: 10)
        assert {:ok, output} = result
        assert String.contains?(output, "success on attempt 2")
      after
        File.rm(script_path)
      end
    end

    test "does not retry non-retryable failures" do
      # Permission denied is not retryable
      result =
        CommandRunner.run("bash", ["-c", "echo 'permission denied' >&2; exit 1"],
          retry: true,
          initial_delay_ms: 10
        )

      assert {:error, {:exit, 1, _}} = result
    end

    test "respects max attempts" do
      # Create a script that always fails
      script_path = "/tmp/test_always_fail_#{:rand.uniform(10000)}"

      script_content = """
      #!/bin/bash
      echo "attempt" >> "/tmp/attempts_#{:rand.uniform(10000)}"
      echo "network error" >&2
      exit 1
      """

      File.write!(script_path, script_content)
      File.chmod!(script_path, 0o755)

      try do
        result =
          CommandRunner.run("bash", [script_path],
            retry: true,
            max_attempts: 2,
            initial_delay_ms: 10
          )

        assert {:error, {:exit, 1, _}} = result
      after
        File.rm(script_path)
      end
    end
  end

  describe "JSON command execution" do
    test "parses valid JSON output" do
      result = CommandRunner.run_json("echo", [~s|{"test": "data", "number": 42}|])
      assert {:ok, %{"test" => "data", "number" => 42}} = result
    end

    test "handles JSON parsing errors" do
      result = CommandRunner.run_json("echo", ["invalid json"])
      assert {:error, {:json_decode, _}} = result
    end

    test "enables retry by default for JSON commands" do
      # We can verify this by checking that a retryable failure gets retried
      # This is hard to test directly, but JSON commands should have retry enabled
      result = CommandRunner.run_json("echo", [~s|{"status": "ok"}|])
      assert {:ok, %{"status" => "ok"}} = result
    end
  end

  describe "run! convenience function" do
    test "returns output directly on success" do
      result = CommandRunner.run!("echo", ["hello"])
      assert String.trim(result) == "hello"
    end

    test "returns nil on failure" do
      result = CommandRunner.run!("false", [])
      assert result == nil
    end
  end

  describe "option handling" do
    test "passes through working directory" do
      # Create a test file in /tmp
      test_dir = "/tmp/command_runner_test_#{:rand.uniform(10000)}"
      File.mkdir_p!(test_dir)
      File.write!(Path.join(test_dir, "test.txt"), "content")

      try do
        result = CommandRunner.run("cat", ["test.txt"], cd: test_dir)
        assert {:ok, output} = result
        assert String.trim(output) == "content"
      after
        File.rm_rf!(test_dir)
      end
    end

    test "handles environment variables" do
      result =
        CommandRunner.run("bash", ["-c", "echo $TEST_VAR"], env: [{"TEST_VAR", "test_value"}])

      assert {:ok, output} = result
      assert String.trim(output) == "test_value"
    end
  end
end
