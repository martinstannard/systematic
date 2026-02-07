defmodule DashboardPhoenix.CommandRunner do
  @moduledoc """
  Safe wrapper around System.cmd with configurable timeouts, rate limiting, and exponential backoff.

  Prevents external CLI calls from blocking indefinitely by wrapping
  them in a Task with a timeout. Includes rate limiting to prevent
  API exhaustion and exponential backoff for retryable failures.

  ## Usage

      # Simple call with default 30s timeout
      CommandRunner.run("git", ["status"])
      
      # With options
      CommandRunner.run("gh", ["pr", "list"], 
        timeout: 60_000,
        cd: "/path/to/repo",
        stderr_to_stdout: true,
        retry: true
      )
      
  ## Returns

      {:ok, output} - Command succeeded (exit code 0)
      {:error, {:exit, code, output}} - Command failed with exit code
      {:error, :timeout} - Command timed out
      {:error, :exception, reason}} - Exception during execution
      {:error, :rate_limited} - Rate limit exceeded
  """

  require Logger

  alias DashboardPhoenix.{RateLimiter, ExponentialBackoff}

  @default_timeout_ms 30_000

  @doc """
  Run an external command with a timeout, rate limiting, and optional retry.

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 30000)
    * `:cd` - Working directory
    * `:stderr_to_stdout` - Merge stderr into stdout (default: true)
    * `:env` - Environment variables as keyword list
    * `:retry` - Enable exponential backoff retry on retryable errors (default: false)
    * `:rate_limit` - Enable rate limiting (default: true)
    * `:max_attempts` - Maximum retry attempts when retry enabled (default: 3)
    
  ## Examples

      iex> CommandRunner.run("echo", ["hello"])
      {:ok, "hello\\n"}
      
      iex> CommandRunner.run("sleep", ["100"], timeout: 100)
      {:error, :timeout}
  """
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, String.t()}
          | {:error, {:exit, integer(), String.t()}}
          | {:error, :timeout}
          | {:error, {:exception, term()}}
          | {:error, :rate_limited}
  def run(command, args, opts \\ []) do
    retry_enabled = Keyword.get(opts, :retry, false)
    rate_limit_enabled = Keyword.get(opts, :rate_limit, true)

    operation = fn ->
      if rate_limit_enabled do
        case RateLimiter.acquire(command) do
          :ok ->
            run_command_internal(command, args, opts)

          {:error, :rate_limited} = error ->
            error
        end
      else
        run_command_internal(command, args, opts)
      end
    end

    if retry_enabled do
      retry_opts = [
        max_attempts: Keyword.get(opts, :max_attempts, 3)
      ]

      ExponentialBackoff.retry_if_retryable(operation, retry_opts)
    else
      operation.()
    end
  end

  # Internal function that actually runs the command
  defp run_command_internal(command, args, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    # Build System.cmd options
    cmd_opts = build_cmd_opts(opts)

    task =
      Task.async(fn ->
        try do
          System.cmd(command, args, cmd_opts)
        rescue
          e -> {:exception, e}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {:exception, reason}} ->
        Logger.warning("CommandRunner exception in #{command}: #{inspect(reason)}")
        {:error, {:exception, reason}}

      {:ok, {output, exit_code}} ->
        {:error, {:exit, exit_code, output}}

      nil ->
        Logger.warning("CommandRunner timeout after #{timeout}ms: #{command} #{inspect(args)}")
        {:error, :timeout}
    end
  end

  @doc """
  Run a command, returning just the output on success or an error tuple.
  Logs warnings on failure. Useful for fire-and-forget commands.
  """
  @spec run!(String.t(), [String.t()], keyword()) :: String.t() | nil
  def run!(command, args, opts \\ []) do
    case run(command, args, opts) do
      {:ok, output} ->
        output

      {:error, reason} ->
        Logger.warning("Command failed: #{command} #{inspect(args)} - #{inspect(reason)}")
        nil
    end
  end

  @doc """
  Run a command expecting JSON output, parse and return the result.

  ## Options

  Same as `run/3`. JSON commands typically benefit from retry enabled.
  """
  @spec run_json(String.t(), [String.t()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def run_json(command, args, opts \\ []) do
    # Enable retry by default for JSON commands (API calls)
    opts_with_retry = Keyword.put_new(opts, :retry, true)

    case run(command, args, opts_with_retry) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      error ->
        error
    end
  end

  # Build options for System.cmd from our options
  defp build_cmd_opts(opts) do
    base_opts = [stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, true)]

    base_opts
    |> maybe_add_opt(:cd, opts)
    |> maybe_add_opt(:env, opts)
  end

  defp maybe_add_opt(cmd_opts, key, opts) do
    case Keyword.get(opts, key) do
      nil -> cmd_opts
      value -> Keyword.put(cmd_opts, key, value)
    end
  end
end
