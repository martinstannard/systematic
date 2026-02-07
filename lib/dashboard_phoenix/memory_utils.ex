defmodule DashboardPhoenix.MemoryUtils do
  @moduledoc """
  Memory management utilities for GenServers.

  Provides:
  - Periodic garbage collection triggers
  - Memory usage monitoring
  - LRU eviction helpers for bounded collections
  - State size telemetry

  ## Usage

  Add to your GenServer:

      # In start_link - enable hibernation
      GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
      
      # In init - schedule periodic GC
      MemoryUtils.schedule_gc()
      
      # In handle_info - handle GC trigger
      def handle_info(:gc_trigger, state) do
        MemoryUtils.trigger_gc(__MODULE__)
        {:noreply, state}
      end
      
      # For collections - use LRU eviction
      new_map = MemoryUtils.lru_evict(map, @max_size, fn {_k, v} -> v.timestamp end)

  ## Ticket #79: GenServer memory optimizations
  """

  require Logger

  # 5 minutes
  @default_gc_interval_ms 300_000
  # Warn if process uses > 100MB
  @memory_warning_threshold_mb 100

  @doc """
  Schedule periodic garbage collection.

  ## Options
  - `:interval_ms` - Time between GC triggers (default: 5 minutes)
  """
  @spec schedule_gc(keyword()) :: reference()
  def schedule_gc(opts \\ []) do
    interval = Keyword.get(opts, :interval_ms, @default_gc_interval_ms)
    Process.send_after(self(), :gc_trigger, interval)
  end

  @doc """
  Trigger garbage collection and log memory usage.

  Returns the memory freed in bytes.
  """
  @spec trigger_gc(atom()) :: {:ok, integer()} | {:ok, :no_gc_needed}
  def trigger_gc(module_name) do
    pid = self()

    # Get memory before GC
    memory_before = Process.info(pid, :memory) |> elem(1)
    heap_before = Process.info(pid, :heap_size) |> elem(1)

    # Only GC if heap is reasonably large (> 1MB worth of words)
    if heap_before > 125_000 do
      :erlang.garbage_collect(pid)

      memory_after = Process.info(pid, :memory) |> elem(1)
      freed = memory_before - memory_after
      freed_mb = freed / (1024 * 1024)
      current_mb = memory_after / (1024 * 1024)

      # Only log if we freed > 100KB
      if freed_mb > 0.1 do
        Logger.debug(
          "#{module_name}: GC freed #{Float.round(freed_mb, 2)}MB, now using #{Float.round(current_mb, 2)}MB"
        )
      end

      # Warn if still using a lot of memory
      if current_mb > @memory_warning_threshold_mb do
        Logger.warning("#{module_name}: High memory usage: #{Float.round(current_mb, 2)}MB")
      end

      {:ok, freed}
    else
      {:ok, :no_gc_needed}
    end
  end

  @doc """
  Evict oldest entries from a map to enforce size limit.

  Uses LRU eviction based on the provided timestamp function.

  ## Examples

      # Evict oldest entries based on :updated_at field
      new_map = MemoryUtils.lru_evict(map, 100, fn {_k, v} -> v.updated_at end)
      
      # Evict based on tuple element
      new_map = MemoryUtils.lru_evict(map, 50, fn {_k, {ts, _data}} -> ts end)
  """
  @spec lru_evict(map(), pos_integer(), (term() -> term())) :: map()
  def lru_evict(map, max_size, timestamp_fn)
      when is_map(map) and is_integer(max_size) and max_size > 0 do
    current_size = map_size(map)

    if current_size <= max_size do
      map
    else
      to_remove = current_size - max_size

      map
      |> Enum.sort_by(timestamp_fn, :asc)
      |> Enum.drop(to_remove)
      |> Map.new()
    end
  end

  @doc """
  Evict oldest entries from a list to enforce size limit.

  Keeps the most recent entries (assumes list is in chronological order, newest first).
  """
  @spec lru_evict_list(list(), pos_integer()) :: list()
  def lru_evict_list(list, max_size)
      when is_list(list) and is_integer(max_size) and max_size > 0 do
    Enum.take(list, max_size)
  end

  @doc """
  Get memory metrics for the current process.
  """
  @spec get_memory_metrics() :: map()
  def get_memory_metrics do
    pid = self()
    info = Process.info(pid, [:memory, :heap_size, :stack_size, :message_queue_len])

    %{
      memory_bytes: info[:memory],
      memory_mb: Float.round(info[:memory] / (1024 * 1024), 2),
      heap_words: info[:heap_size],
      stack_words: info[:stack_size],
      message_queue_len: info[:message_queue_len]
    }
  end

  @doc """
  Log periodic telemetry for a GenServer.

  Call this periodically (e.g., every 5 minutes) to track memory trends.
  """
  @spec log_telemetry(atom(), map()) :: :ok
  def log_telemetry(module_name, extra_metrics \\ %{}) do
    metrics = get_memory_metrics()
    combined = Map.merge(metrics, extra_metrics)

    formatted =
      combined
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
      |> Enum.join(", ")

    Logger.info("#{module_name} telemetry: #{formatted}")
    :ok
  end

  @doc """
  Common hibernation timeout for GenServers (15 seconds of idle).
  """
  @spec hibernate_after() :: pos_integer()
  def hibernate_after, do: 15_000
end
