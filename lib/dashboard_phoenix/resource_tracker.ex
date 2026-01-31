defmodule DashboardPhoenix.ResourceTracker do
  @moduledoc """
  Tracks CPU and memory usage over time for system processes.
  Samples every 5 seconds and keeps a rolling window of 60 data points (5 minutes).
  """
  use GenServer

  require Logger

  alias DashboardPhoenix.CommandRunner

  @sample_interval 5_000  # 5 seconds
  @max_history 60  # 5 minutes of history at 5-second intervals
  @interesting_patterns ~w(opencode openclaw claude codex)
  @cli_timeout_ms 10_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Get the full history for all tracked processes.
  Returns %{pid => [{timestamp, cpu, memory}, ...]}
  """
  def get_history do
    GenServer.call(__MODULE__, :get_history)
  end

  @doc """
  Get history for a specific PID.
  """
  def get_history(pid) do
    GenServer.call(__MODULE__, {:get_history, pid})
  end

  @doc """
  Get the current snapshot of all tracked processes with their latest stats.
  """
  def get_current do
    GenServer.call(__MODULE__, :get_current)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "resource_updates")
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    schedule_sample()
    {:ok, %{history: %{}, last_sample: nil}}
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    {:reply, state.history, state}
  end

  @impl true
  def handle_call({:get_history, pid}, _from, state) do
    {:reply, Map.get(state.history, pid, []), state}
  end

  @impl true
  def handle_call(:get_current, _from, state) do
    current = state.history
    |> Enum.map(fn {pid, history} ->
      case List.first(history) do
        {ts, cpu, mem} -> {pid, %{timestamp: ts, cpu: cpu, memory: mem, history: history}}
        nil -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
    
    {:reply, current, state}
  end

  @impl true
  def handle_info(:sample, state) do
    new_state = sample_processes(state)
    schedule_sample()
    {:noreply, new_state}
  end

  defp schedule_sample do
    Process.send_after(self(), :sample, @sample_interval)
  end

  defp sample_processes(state) do
    timestamp = System.system_time(:millisecond)
    processes = fetch_process_stats()
    
    # Update history for each process
    new_history = Enum.reduce(processes, state.history, fn proc, acc ->
      pid = proc.pid
      data_point = {timestamp, proc.cpu, proc.memory_kb}
      
      existing = Map.get(acc, pid, [])
      updated = [data_point | existing] |> Enum.take(@max_history)
      
      Map.put(acc, pid, updated)
    end)
    
    # Remove processes that are no longer running (haven't been seen in 2 samples)
    current_pids = MapSet.new(Enum.map(processes, & &1.pid))
    cleaned_history = new_history
    |> Enum.filter(fn {pid, history} ->
      MapSet.member?(current_pids, pid) or 
        (length(history) > 0 and elem(hd(history), 0) > timestamp - @sample_interval * 2)
    end)
    |> Map.new()
    
    # Broadcast update
    broadcast_update(cleaned_history, processes)
    
    %{state | history: cleaned_history, last_sample: timestamp}
  end

  defp fetch_process_stats do
    case CommandRunner.run("ps", ["aux", "--sort=-pcpu"], timeout: @cli_timeout_ms) do
      {:ok, output} ->
        output
        |> String.split("\n")
        |> Enum.drop(1)  # Skip header
        |> Enum.filter(&interesting_process?/1)
        |> Enum.take(30)
        |> Enum.map(&parse_process_line/1)
        |> Enum.reject(&is_nil/1)
        
      {:error, reason} ->
        Logger.warning("Failed to fetch process stats: #{inspect(reason)}")
        []
    end
  end

  defp interesting_process?(line) do
    line_lower = String.downcase(line)
    Enum.any?(@interesting_patterns, &String.contains?(line_lower, &1))
  end

  defp parse_process_line(line) do
    parts = String.split(line, ~r/\s+/, parts: 11)
    
    case parts do
      [_user, pid, cpu, _mem, _vsz, rss, _tty, _stat, _start, _time, command | _] ->
        %{
          pid: pid,
          cpu: parse_float(cpu),
          memory_kb: parse_int(rss),
          command: String.slice(command, 0, 80)
        }
      _ ->
        nil
    end
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> 0.0
    end
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {val, _} -> val
      :error -> 0
    end
  end

  defp broadcast_update(history, current_processes) do
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "resource_updates", 
      {:resource_update, %{history: history, current: current_processes}})
  end
end
