defmodule DashboardPhoenix.CLICache do
  @moduledoc """
  Simple TTL cache for expensive CLI command results.
  
  Reduces system load by caching command output and avoiding redundant calls
  within the TTL window. Implements:
  - Per-command caching with configurable TTL
  - Automatic cache expiration
  - Thread-safe access via ETS
  
  ## Usage
  
      # Cache a command result for 30 seconds
      case CLICache.get_or_fetch("gh:pr:list:repo", 30_000, fn ->
        System.cmd("gh", ["pr", "list", "--repo", repo])
      end) do
        {:ok, output} -> process(output)
        {:error, reason} -> handle_error(reason)
      end
  
  Ticket #73: Reduce external CLI command overhead
  """

  use GenServer
  require Logger

  @ets_table :cli_cache
  @cleanup_interval_ms 60_000  # Clean expired entries every minute

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get a cached value or fetch it using the provided function.
  
  ## Parameters
  - `key` - Unique cache key for the command (e.g., "gh:pr:list:Fresh-Clinics/core-platform")
  - `ttl_ms` - Time-to-live in milliseconds
  - `fetch_fn` - Function to execute if cache miss. Should return `{:ok, result}` or `{:error, reason}`
  
  ## Returns
  - `{:ok, result}` - Cached or freshly fetched result
  - `{:error, reason}` - Error from fetch_fn (not cached)
  """
  def get_or_fetch(key, ttl_ms, fetch_fn) when is_binary(key) and is_integer(ttl_ms) and is_function(fetch_fn, 0) do
    now = System.system_time(:millisecond)
    
    case :ets.lookup(@ets_table, key) do
      [{^key, result, expires_at}] when expires_at > now ->
        Logger.debug("CLICache HIT: #{key}")
        {:ok, result}
      
      _ ->
        Logger.debug("CLICache MISS: #{key}")
        case fetch_fn.() do
          {:ok, result} ->
            expires_at = now + ttl_ms
            :ets.insert(@ets_table, {key, result, expires_at})
            {:ok, result}
          
          {:error, _reason} = error ->
            # Don't cache errors
            error
        end
    end
  end

  @doc """
  Invalidate a specific cache entry.
  """
  def invalidate(key) when is_binary(key) do
    :ets.delete(@ets_table, key)
    :ok
  end

  @doc """
  Invalidate all cache entries matching a prefix.
  Useful for clearing all entries for a specific tool (e.g., "gh:" or "linear:").
  """
  def invalidate_prefix(prefix) when is_binary(prefix) do
    :ets.foldl(fn {key, _result, _expires}, acc ->
      if String.starts_with?(key, prefix) do
        :ets.delete(@ets_table, key)
        acc + 1
      else
        acc
      end
    end, 0, @ets_table)
  end

  @doc """
  Clear all cache entries.
  """
  def clear do
    :ets.delete_all_objects(@ets_table)
    :ok
  end

  @doc """
  Get cache statistics.
  """
  def stats do
    now = System.system_time(:millisecond)
    
    {total, valid, expired} = :ets.foldl(fn {_key, _result, expires_at}, {t, v, e} ->
      if expires_at > now do
        {t + 1, v + 1, e}
      else
        {t + 1, v, e + 1}
      end
    end, {0, 0, 0}, @ets_table)
    
    %{
      total_entries: total,
      valid_entries: valid,
      expired_entries: expired,
      memory_bytes: :ets.info(@ets_table, :memory) * :erlang.system_info(:wordsize)
    }
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for cache storage
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    
    # Schedule periodic cleanup
    schedule_cleanup()
    
    Logger.info("CLICache initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_expired()
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_expired do
    now = System.system_time(:millisecond)
    
    expired_count = :ets.foldl(fn {key, _result, expires_at}, acc ->
      if expires_at <= now do
        :ets.delete(@ets_table, key)
        acc + 1
      else
        acc
      end
    end, 0, @ets_table)
    
    if expired_count > 0 do
      Logger.debug("CLICache cleanup: removed #{expired_count} expired entries")
    end
  end
end
