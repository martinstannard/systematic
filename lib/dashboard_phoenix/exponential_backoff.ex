defmodule DashboardPhoenix.ExponentialBackoff do
  @moduledoc """
  Exponential backoff retry logic for external API calls.
  
  Implements exponential backoff with jitter to avoid thundering herd
  problems when multiple processes retry failed operations.
  
  ## Usage
  
      # Simple retry with default settings
      ExponentialBackoff.retry(fn -> 
        CommandRunner.run("gh", ["pr", "list"])
      end)
      
      # With custom options
      ExponentialBackoff.retry(fn -> 
        some_operation()
      end, max_attempts: 5, initial_delay_ms: 100)
  """
  
  require Logger

  @type retry_opts :: [
    max_attempts: pos_integer(),
    initial_delay_ms: pos_integer(),
    max_delay_ms: pos_integer(),
    backoff_factor: float(),
    jitter: boolean()
  ]

  @default_opts [
    max_attempts: 3,
    initial_delay_ms: 250,
    max_delay_ms: 8_000,
    backoff_factor: 2.0,
    jitter: true
  ]

  @doc """
  Retry a function with exponential backoff.
  
  The function should return {:ok, result} on success or {:error, reason} on failure.
  
  ## Options
  
    * `:max_attempts` - Maximum number of attempts (default: 3)
    * `:initial_delay_ms` - Initial delay in milliseconds (default: 250)
    * `:max_delay_ms` - Maximum delay in milliseconds (default: 8000)
    * `:backoff_factor` - Multiplier for delay on each retry (default: 2.0)
    * `:jitter` - Add random jitter to delays (default: true)
    
  ## Returns
  
    * `{:ok, result}` - Success after attempt N
    * `{:error, reason}` - All attempts failed
  """
  @spec retry(fun(), retry_opts()) :: {:ok, term()} | {:error, term()}
  def retry(fun, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    do_retry(fun, opts, 1, [])
  end

  # Internal retry loop
  defp do_retry(fun, opts, attempt, previous_errors) do
    max_attempts = Keyword.get(opts, :max_attempts)
    
    case fun.() do
      {:ok, result} ->
        if attempt > 1 do
          Logger.info("Operation succeeded on attempt #{attempt}/#{max_attempts}")
        end
        {:ok, result}
        
      {:error, reason} = error ->
        updated_errors = [reason | previous_errors]
        
        if attempt >= max_attempts do
          Logger.warning("Operation failed after #{attempt} attempts. Errors: #{inspect(Enum.reverse(updated_errors))}")
          error
        else
          delay_ms = calculate_delay(opts, attempt)
          Logger.debug("Operation failed on attempt #{attempt}/#{max_attempts}, retrying in #{delay_ms}ms. Error: #{inspect(reason)}")
          
          Process.sleep(delay_ms)
          do_retry(fun, opts, attempt + 1, updated_errors)
        end
    end
  end

  # Calculate delay for the given attempt
  defp calculate_delay(opts, attempt) do
    initial_delay = Keyword.get(opts, :initial_delay_ms)
    max_delay = Keyword.get(opts, :max_delay_ms)
    factor = Keyword.get(opts, :backoff_factor)
    jitter? = Keyword.get(opts, :jitter)
    
    # Exponential backoff: initial_delay * factor^(attempt-1)
    delay = initial_delay * :math.pow(factor, attempt - 1)
    
    # Cap at max_delay
    delay = min(delay, max_delay)
    
    # Add jitter if enabled
    if jitter? do
      add_jitter(delay)
    else
      round(delay)
    end
  end

  # Add random jitter (±25% of delay) to prevent thundering herd
  defp add_jitter(delay) do
    jitter_amount = delay * 0.25
    min_delay = delay - jitter_amount
    max_delay = delay + jitter_amount
    
    min_delay + :rand.uniform() * (max_delay - min_delay)
    |> round()
    |> max(0)  # Ensure non-negative
  end

  @doc """
  Determine if an error is retryable.
  
  Some errors (like timeouts, network issues) are worth retrying.
  Others (like authentication failures, bad arguments) are not.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(:timeout), do: true
  def retryable?({:exit, code, _output}) when code in [124, 125, 126, 127], do: true  # Command not found, etc
  def retryable?({:exit, code, output}) do
    # Check for common retryable error patterns
    output_lower = String.downcase(output)
    
    cond do
      # Non-retryable patterns first
      String.contains?(output_lower, ["authentication failed", "permission denied", "access denied"]) -> false
      String.contains?(output_lower, ["not found", "invalid", "unauthorized"]) -> false
      
      # Network/API issues
      String.contains?(output_lower, ["network", "timeout", "connection", "rate limit"]) -> true
      String.contains?(output_lower, ["502", "503", "504", "429"]) -> true  # HTTP errors
      String.contains?(output_lower, ["temporarily unavailable", "try again"]) -> true
      
      # GitHub specific
      String.contains?(output_lower, "api rate limit exceeded") -> true
      String.contains?(output_lower, "abuse detection") -> true
      
      # Linear specific  
      String.contains?(output_lower, "rate limited") -> true
      
      # Exit codes suggesting temporary issues
      code in [1, 2] -> true  # Generic failures worth retrying
      
      true -> false
    end
  end
  def retryable?({:exception, %{__struct__: exception_type}}) do
    # Certain exceptions are worth retrying
    case exception_type do
      System.SubprocessError -> true
      _ -> false
    end
  end
  def retryable?(_), do: false

  @doc """
  Retry only if the error is retryable, otherwise return immediately.
  """
  @spec retry_if_retryable(fun(), retry_opts()) :: {:ok, term()} | {:error, term()}
  def retry_if_retryable(fun, opts \\ []) do
    case fun.() do
      {:error, reason} = error ->
        if retryable?(reason) do
          Logger.debug("Error is retryable, will retry: #{inspect(reason)}")
          retry(fun, opts)
        else
          Logger.debug("Error is not retryable, failing immediately: #{inspect(reason)}")
          error
        end
      
      success ->
        success
    end
  end
end