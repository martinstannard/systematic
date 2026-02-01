defmodule DashboardPhoenix.RateLimiter do
  @moduledoc """
  Rate limiter using token bucket algorithm for external API calls.
  
  Prevents rate limit exhaustion by limiting the number of requests
  per time window per command type.
  
  ## Usage
  
      # Check if a command can run
      case RateLimiter.acquire("gh") do
        :ok -> 
          # Command is allowed, proceed
          :allowed
        {:error, :rate_limited} ->
          # Rate limited, wait or fail
          :denied
      end
      
      # Wait for permission (blocks until token available)
      RateLimiter.acquire_wait("linear")
  """
  
  use GenServer
  require Logger

  # Rate limits per command type (requests per minute)
  @rate_limits %{
    "gh" => 30,        # GitHub CLI - 30 requests per minute
    "linear" => 40,    # Linear CLI - 40 requests per minute  
    "git" => 100,      # Git commands - higher limit
    :default => 20     # Default for unknown commands
  }

  # Bucket size (max burst) - usually same as rate limit
  @bucket_sizes %{
    "gh" => 30,
    "linear" => 40,
    "git" => 100,
    :default => 20
  }

  @refill_interval_ms 1_000  # Refill tokens every 1 second

  defstruct [:buckets, :last_refill]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Try to acquire a token for the given command.
  Returns :ok if allowed, {:error, :rate_limited} if not.
  """
  def acquire(command) do
    GenServer.call(__MODULE__, {:acquire, command})
  end

  @doc """
  Acquire a token, waiting if necessary.
  Blocks until a token becomes available.
  """
  def acquire_wait(command, max_wait_ms \\ 30_000) do
    case acquire(command) do
      :ok -> 
        :ok
      {:error, :rate_limited} ->
        # Wait and retry
        wait_time = min(1000, max_wait_ms)
        if max_wait_ms > 0 do
          Process.sleep(wait_time)
          acquire_wait(command, max_wait_ms - wait_time)
        else
          {:error, :timeout}
        end
    end
  end

  @doc """
  Get current bucket states (for debugging/monitoring)
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Reset all rate limit buckets to full tokens.
  Useful for test isolation to ensure each test starts with fresh limits.
  """
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # Server implementation

  @impl true
  def init(_opts) do
    # Initialize buckets with full tokens
    buckets = 
      @rate_limits
      |> Enum.into(%{}, fn {command, limit} ->
        bucket_size = Map.get(@bucket_sizes, command, limit)
        {command, %{tokens: bucket_size, max_tokens: bucket_size}}
      end)

    # Schedule token refill
    Process.send_after(self(), :refill, @refill_interval_ms)

    state = %__MODULE__{
      buckets: buckets,
      last_refill: System.monotonic_time(:millisecond)
    }

    Logger.info("RateLimiter started with limits: #{inspect(@rate_limits)}")
    {:ok, state}
  end

  @impl true
  def handle_call({:acquire, command}, _from, state) do
    bucket_key = get_bucket_key(command)
    bucket = Map.get(state.buckets, bucket_key)
    
    if bucket.tokens > 0 do
      # Token available, consume it
      updated_bucket = %{bucket | tokens: bucket.tokens - 1}
      updated_buckets = Map.put(state.buckets, bucket_key, updated_bucket)
      new_state = %{state | buckets: updated_buckets}
      
      Logger.debug("Rate limit token acquired for #{command} (#{updated_bucket.tokens}/#{updated_bucket.max_tokens} remaining)")
      {:reply, :ok, new_state}
    else
      # No tokens available
      Logger.debug("Rate limit exceeded for #{command}")
      {:reply, {:error, :rate_limited}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    # Reset all buckets to full tokens for test isolation
    buckets = 
      @rate_limits
      |> Enum.into(%{}, fn {command, limit} ->
        bucket_size = Map.get(@bucket_sizes, command, limit)
        {command, %{tokens: bucket_size, max_tokens: bucket_size}}
      end)

    new_state = %{state | 
      buckets: buckets,
      last_refill: System.monotonic_time(:millisecond)
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:refill, state) do
    now = System.monotonic_time(:millisecond)
    elapsed_ms = now - state.last_refill
    
    # Calculate how many tokens to add based on elapsed time
    # Each bucket gets rate_limit / 60 tokens per second
    updated_buckets = 
      Enum.into(state.buckets, %{}, fn {command, bucket} ->
        rate_per_minute = Map.get(@rate_limits, command, @rate_limits[:default])
        tokens_per_second = rate_per_minute / 60.0
        new_tokens = (elapsed_ms / 1000.0) * tokens_per_second
        
        # Add tokens but don't exceed max
        updated_tokens = min(bucket.max_tokens, bucket.tokens + new_tokens)
        updated_bucket = %{bucket | tokens: updated_tokens}
        
        {command, updated_bucket}
      end)

    new_state = %{state | 
      buckets: updated_buckets,
      last_refill: now
    }

    # Schedule next refill
    Process.send_after(self(), :refill, @refill_interval_ms)
    
    {:noreply, new_state}
  end

  # Get the bucket key for a command
  defp get_bucket_key(command) when is_binary(command) do
    # Normalize: try full path first, then basename (for /path/to/linear -> "linear")
    basename = Path.basename(command)
    cond do
      Map.has_key?(@rate_limits, command) -> command
      Map.has_key?(@rate_limits, basename) -> basename
      true -> :default
    end
  end
  defp get_bucket_key(_), do: :default
end