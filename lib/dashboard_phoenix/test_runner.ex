defmodule DashboardPhoenix.TestRunner do
  @moduledoc """
  Manages test execution and logs test results to ActivityLog.

  Provides functionality to run tests (mix test) and automatically
  log the results as :test_passed or :test_failed events.

  ## Usage

      # Run all tests
      TestRunner.run_tests()

      # Run tests for specific files
      TestRunner.run_tests(["test/specific_test.exs"])

      # Run with custom options
      TestRunner.run_tests([], ["--seed", "0"])
  """

  require Logger
  alias DashboardPhoenix.{ActivityLog, CommandRunner, Paths}

  @cli_timeout_ms 300_000  # 5 minutes for test runs
  @test_file_pattern ~r/(\d+) tests?, (\d+) failures?/
  @error_pattern ~r/(\d+) tests?, (\d+) failures?, (\d+) errors?/

  defp repo_path, do: Paths.systematic_repo()

  @doc """
  Run tests and log the results.

  ## Parameters
  - `test_files` - List of specific test files to run (default: all tests)
  - `extra_args` - Additional arguments to pass to mix test (default: [])

  ## Returns
  - `{:ok, output}` - Tests completed (may have passed or failed)
  - `{:error, reason}` - Unable to run tests

  Test results are automatically logged to ActivityLog.
  """
  @spec run_tests(list(String.t()), list(String.t())) :: {:ok, String.t()} | {:error, term()}
  def run_tests(test_files \\ [], extra_args \\ []) do
    Logger.info("TestRunner: Starting test run...")
    
    args = build_test_args(test_files, extra_args)
    
    case CommandRunner.run("mix", ["test" | args],
           cd: repo_path(),
           timeout: @cli_timeout_ms,
           stderr_to_stdout: true
         ) do
      {:ok, output} ->
        # mix test returns 0 even when there are failures, parse output to determine result
        {passed, failed, errors} = parse_test_output(output)
        log_test_result(passed, failed, errors, output)
        {:ok, output}

      {:error, {:exit, exit_code, output}} ->
        # Non-zero exit usually means compilation errors or test crashes
        Logger.warning("TestRunner: Tests failed with exit code #{exit_code}")
        
        # Try to parse any test results from the output
        {passed, failed, errors} = parse_test_output(output)
        
        if passed + failed > 0 do
          # Got some test results before crash
          log_test_result(passed, failed, errors, output)
        else
          # No test results, likely compilation error
          ActivityLog.log_event(:test_failed, "Tests failed to run (compilation error)", %{
            exit_code: exit_code,
            output_preview: String.slice(output, 0, 500)
          })
        end
        
        {:ok, output}

      {:error, reason} ->
        Logger.error("TestRunner: Failed to run tests: #{inspect(reason)}")
        ActivityLog.log_event(:test_failed, "Tests failed to run (command error)", %{
          reason: inspect(reason)
        })
        {:error, reason}
    end
  end

  @doc """
  Quick test check - runs tests and returns just pass/fail status.
  """
  @spec quick_test_check() :: :passed | :failed | :error
  def quick_test_check do
    case run_tests() do
      {:ok, output} ->
        {_passed, failed, errors} = parse_test_output(output)
        if failed == 0 and errors == 0, do: :passed, else: :failed

      {:error, _} ->
        :error
    end
  end

  @doc """
  Run tests for a specific module or pattern.
  
  ## Examples
  
      TestRunner.run_tests_for("ActivityLog")
      TestRunner.run_tests_for("lib/dashboard_phoenix/activity_log.ex")
  """
  @spec run_tests_for(String.t()) :: {:ok, String.t()} | {:error, term()}
  def run_tests_for(pattern) when is_binary(pattern) do
    # If it looks like a file path, run that file
    # Otherwise, treat as a pattern for --only
    if String.contains?(pattern, "/") or String.ends_with?(pattern, ".exs") do
      run_tests([pattern])
    else
      run_tests([], ["--only", pattern])
    end
  end

  # Private functions

  defp build_test_args(test_files, extra_args) do
    test_files ++ extra_args
  end

  defp parse_test_output(output) do
    # Look for patterns like:
    # "5 tests, 0 failures"
    # "3 tests, 1 failure, 2 errors"
    # "Finished in 0.1 seconds (0.05s async, 0.05s sync)"
    
    cond do
      # Pattern with errors
      match = Regex.run(@error_pattern, output) ->
        [_, total_str, failures_str, errors_str] = match
        total = String.to_integer(total_str)
        failures = String.to_integer(failures_str)
        errors = String.to_integer(errors_str)
        passed = total - failures - errors
        {max(passed, 0), failures, errors}

      # Pattern without errors
      match = Regex.run(@test_file_pattern, output) ->
        [_, total_str, failures_str] = match
        total = String.to_integer(total_str)
        failures = String.to_integer(failures_str)
        passed = total - failures
        {max(passed, 0), failures, 0}

      true ->
        # No recognizable pattern found
        {0, 0, 1}  # Assume error
    end
  end

  defp log_test_result(passed, failed, errors, output) do
    total_issues = failed + errors
    
    if total_issues == 0 do
      ActivityLog.log_event(:test_passed, "All tests passed (#{passed} tests)", %{
        passed: passed,
        failed: failed,
        errors: errors,
        total: passed + failed + errors
      })
    else
      message = format_failure_message(passed, failed, errors)
      
      # Include a preview of failures in details
      failure_preview = extract_failure_preview(output)
      
      ActivityLog.log_event(:test_failed, message, %{
        passed: passed,
        failed: failed,
        errors: errors,
        total: passed + failed + errors,
        failure_preview: failure_preview
      })
    end
  end

  defp format_failure_message(passed, failed, errors) do
    total = passed + failed + errors
    issues = failed + errors
    
    cond do
      failed > 0 and errors > 0 ->
        "Tests failed: #{failed} failures, #{errors} errors (#{passed}/#{total} passed)"
      failed > 0 ->
        "Tests failed: #{failed} failures (#{passed}/#{total} passed)"
      errors > 0 ->
        "Tests failed: #{errors} errors (#{passed}/#{total} passed)"
      true ->
        "Tests failed: #{issues} issues (#{passed}/#{total} passed)"
    end
  end

  defp extract_failure_preview(output) do
    # Find lines around failure indicators
    lines = String.split(output, "\n")
    
    failure_lines = 
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _} -> 
        String.contains?(line, "FAIL") or 
        String.contains?(line, "Error") or
        String.contains?(line, "** (") 
      end)
      |> Enum.take(3)  # Max 3 failure examples
      |> Enum.map(fn {line, _} -> String.slice(line, 0, 150) end)
    
    if failure_lines == [] do
      "No specific failure details found"
    else
      Enum.join(failure_lines, "\n")
    end
  end
end