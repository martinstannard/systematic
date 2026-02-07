defmodule DashboardPhoenix.ResourceTracker do
  @moduledoc """
  Tracks CPU and memory usage over time for system processes.
  Samples every 5 seconds and keeps a rolling window of 60 data points (5 minutes).

  ## Performance Optimizations (Ticket #71)

  - Uses ETS for fast data reads (no GenServer.call blocking)
  - GenServer only manages lifecycle and periodic sampling
  - All public getters read directly from ETS
  """
  use GenServer

  require Logger

  alias DashboardPhoenix.ProcessParser
  alias DashboardPhoenix.PubSub.Topics

  # 10 seconds (Ticket #73: reduced from 5s to lower CLI overhead)
  @sample_interval 10_000
  # 5 minutes of history at 5-second intervals
  @max_history 60
  @interesting_patterns ~w(opencode openclaw claude codex)
  @cli_timeout_ms 10_000
  # Limit total number of tracked processes
  @max_tracked_processes 100
  # Remove processes inactive for 2 minutes
  @process_inactive_threshold 120_000
  # Trigger GC every 5 minutes (Ticket #79)
  @gc_interval 300_000

  # ETS table name for fast reads
  @ets_table :resource_tracker_data

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc """
  Get the full history for all tracked processes.
  Returns %{pid => [{timestamp, cpu, memory}, ...]}
  Reads directly from ETS (non-blocking).
  """
  def get_history do
    case :ets.lookup(@ets_table, :history) do
      [{:history, history}] -> history
      [] -> %{}
    end
  end

  @doc """
  Get history for a specific PID.
  Reads directly from ETS (non-blocking).
  """
  def get_history(pid) do
    history = get_history()
    Map.get(history, pid, [])
  end

  @doc """
  Get the current snapshot of all tracked processes with their latest stats.
  Reads directly from ETS (non-blocking).
  """
  def get_current do
    case :ets.lookup(@ets_table, :current) do
      [{:current, current}] -> current
      [] -> %{}
    end
  end

  @doc """
  Get state metrics for telemetry monitoring.
  Reads directly from ETS (non-blocking).
  """
  def get_state_metrics do
    case :ets.lookup(@ets_table, :metrics) do
      [{:metrics, metrics}] ->
        metrics

      [] ->
        %{
          tracked_processes: 0,
          total_history_points: 0,
          last_sample: nil,
          memory_usage_mb: :erlang.memory(:total) / (1024 * 1024),
          max_tracked_processes: @max_tracked_processes,
          max_history_per_process: @max_history
        }
    end
  end

  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, Topics.resource_updates())
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    # Create ETS table for fast reads (Ticket #71)
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])

    # Initialize ETS with empty data
    :ets.insert(@ets_table, {:history, %{}})
    :ets.insert(@ets_table, {:current, %{}})

    :ets.insert(
      @ets_table,
      {:metrics,
       %{
         tracked_processes: 0,
         total_history_points: 0,
         last_sample: nil,
         memory_usage_mb: 0,
         max_tracked_processes: @max_tracked_processes,
         max_history_per_process: @max_history
       }}
    )

    schedule_sample()
    schedule_gc()
    {:ok, %{history: %{}, last_sample: nil}}
  end

  @impl true
  def handle_info(:sample, state) do
    new_state = sample_processes(state)
    schedule_sample()
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:gc_trigger, state) do
    alias DashboardPhoenix.MemoryUtils
    MemoryUtils.trigger_gc(__MODULE__)
    schedule_gc()
    {:noreply, state}
  end

  defp schedule_sample do
    Process.send_after(self(), :sample, @sample_interval)
  end

  defp schedule_gc do
    Process.send_after(self(), :gc_trigger, @gc_interval)
  end

  defp sample_processes(state) do
    timestamp = System.system_time(:millisecond)
    processes = fetch_process_stats()

    # Update history for each process
    new_history =
      Enum.reduce(processes, state.history, fn proc, acc ->
        pid = proc.pid
        data_point = {timestamp, proc.cpu, proc.memory_kb}

        existing = Map.get(acc, pid, [])
        updated = [data_point | existing] |> Enum.take(@max_history)

        Map.put(acc, pid, updated)
      end)

    # Improved cleanup: remove stale processes and enforce size limits
    current_pids = MapSet.new(Enum.map(processes, & &1.pid))

    # Filter out inactive processes (not seen for @process_inactive_threshold)
    cleaned_history =
      new_history
      |> Enum.filter(fn {pid, history} ->
        is_active = MapSet.member?(current_pids, pid)

        is_recent =
          length(history) > 0 and elem(hd(history), 0) > timestamp - @process_inactive_threshold

        is_active or is_recent
      end)
      |> Map.new()

    # Enforce max_tracked_processes limit: keep most active/recent processes
    final_history =
      if map_size(cleaned_history) > @max_tracked_processes do
        require Logger

        Logger.info(
          "ResourceTracker: Process limit exceeded (#{map_size(cleaned_history)}), pruning to #{@max_tracked_processes}"
        )

        cleaned_history
        |> Enum.map(fn {pid, history} ->
          # Score by recency and activity level
          latest_timestamp = if length(history) > 0, do: elem(hd(history), 0), else: 0
          is_currently_running = MapSet.member?(current_pids, pid)
          score = latest_timestamp + if is_currently_running, do: timestamp, else: 0
          {pid, history, score}
        end)
        |> Enum.sort_by(fn {_pid, _history, score} -> score end, :desc)
        |> Enum.take(@max_tracked_processes)
        |> Enum.map(fn {pid, history, _score} -> {pid, history} end)
        |> Map.new()
      else
        cleaned_history
      end

    # Log periodic telemetry
    # Every 5 minutes
    if rem(div(timestamp, @sample_interval), 60) == 0 do
      total_points = final_history |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
      require Logger

      Logger.info(
        "ResourceTracker telemetry: tracked_processes=#{map_size(final_history)}/#{@max_tracked_processes}, total_history_points=#{total_points}"
      )
    end

    # Update ETS with current data (Ticket #71)
    update_ets(final_history, timestamp)

    # Broadcast update
    broadcast_update(final_history, processes)

    %{state | history: final_history, last_sample: timestamp}
  end

  # Write current state to ETS for non-blocking reads (Ticket #71)
  defp update_ets(history, timestamp) do
    # Compute current snapshot from history
    current =
      history
      |> Enum.map(fn {pid, hist} ->
        case List.first(hist) do
          {ts, cpu, mem} -> {pid, %{timestamp: ts, cpu: cpu, memory: mem, history: hist}}
          nil -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    total_history_points =
      history
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.sum()

    :ets.insert(@ets_table, {:history, history})
    :ets.insert(@ets_table, {:current, current})

    :ets.insert(
      @ets_table,
      {:metrics,
       %{
         tracked_processes: map_size(history),
         total_history_points: total_history_points,
         last_sample: timestamp,
         memory_usage_mb: :erlang.memory(:total) / (1024 * 1024),
         max_tracked_processes: @max_tracked_processes,
         max_history_per_process: @max_history
       }}
    )
  end

  defp fetch_process_stats do
    ProcessParser.list_processes(
      sort: "-pcpu",
      filter: &ProcessParser.contains_patterns?(&1, @interesting_patterns),
      limit: 30,
      timeout: @cli_timeout_ms
    )
    |> Enum.map(&transform_to_tracker_process/1)
  end

  defp transform_to_tracker_process(%{pid: pid, cpu: cpu, rss: rss, command: command}) do
    %{
      pid: pid,
      cpu: cpu,
      memory_kb: parse_memory_kb(rss),
      command: ProcessParser.truncate_command(command, 80)
    }
  end

  defp parse_memory_kb(rss_str) when is_binary(rss_str) do
    case Integer.parse(rss_str) do
      {val, _} -> val
      :error -> 0
    end
  end

  defp parse_memory_kb(_), do: 0

  defp broadcast_update(history, current_processes) do
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      Topics.resource_updates(),
      {:resource_update, %{history: history, current: current_processes}}
    )
  end
end
