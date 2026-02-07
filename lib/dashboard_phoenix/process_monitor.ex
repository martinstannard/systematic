defmodule DashboardPhoenix.ProcessMonitor do
  @moduledoc """
  Monitors system processes relevant to the dashboard.

  This module interacts with the system's process table to track specific 
  applications like OpenCode, OpenClaw, and others.

  It provides functionality to:
  - List and filter interesting processes based on predefined patterns.
  - Transform raw process data into a dashboard-friendly format (structs).
  - Calculate aggregate statistics (running, busy, idle counts).
  """

  require Logger

  alias DashboardPhoenix.{ProcessParser, Paths, Status}

  @interesting_patterns ~w(opencode openclaw-tui openclaw-gateway)

  @doc """
  Lists interesting processes filtered by `@interesting_patterns`.

  Returns a list of dashboard-friendly process maps with the following keys:
  - `:name` - Auto-generated process name
  - `:pid` - Process ID
  - `:status` - Derived status (busy, idle, etc.)
  - `:cpu_usage` - CPU percentage as string
  - `:memory_usage` - Formatted memory usage
  - `:command` - Truncated command string
  - `:directory` - Working directory
  - `:model` - Detected AI model (if any)

  ## Examples

      iex> DashboardPhoenix.ProcessMonitor.list_processes()
      [%{name: "agent_1234", pid: "1234", status: :busy, ...}, ...]

  """
  @spec list_processes() :: [map()]
  def list_processes do
    ProcessParser.list_processes(
      sort: "-pcpu",
      filter: &interesting_process?/1,
      limit: 20
    )
    |> Enum.map(&transform_to_dashboard_process/1)
  end

  defp interesting_process?(line) do
    ProcessParser.contains_patterns?(line, @interesting_patterns)
  end

  defp transform_to_dashboard_process(%{
         pid: pid,
         cpu: cpu,
         stat: stat,
         time: time,
         command: command,
         rss: rss,
         start: start
       }) do
    %{
      name: ProcessParser.generate_name(pid),
      pid: pid,
      status: ProcessParser.derive_status(stat, cpu),
      time: time,
      command: ProcessParser.truncate_command(command),
      directory: extract_directory(command),
      details: command,
      cpu_usage: "#{cpu}%",
      memory_usage: ProcessParser.format_memory(rss),
      model: detect_model(command),
      tokens: %{input: 0, output: 0, total: 0},
      exit_code: nil,
      last_output: nil,
      runtime: time,
      start_time: start
    }
  end

  defp extract_directory(command) do
    cond do
      String.contains?(command, "dashboard_phoenix") -> Paths.dashboard_phoenix_dir()
      String.contains?(command, "clawd") -> Paths.clawd_dir()
      String.contains?(command, "opencode") -> "~"
      true -> "/"
    end
  end

  defp detect_model(command) do
    cond do
      String.contains?(command, "opencode") -> "claude-sonnet-4"
      String.contains?(command, "openclaw") -> "claude-sonnet-4"
      true -> "N/A (System)"
    end
  end

  @doc """
  Calculates aggregate statistics from a list of processes.

  ## Parameters

  - `processes` - List of process maps from `list_processes/0`

  ## Returns

  A map with the following keys:
  - `:running` - Total active (busy + idle)
  - `:busy` - Count of busy processes
  - `:idle` - Count of idle processes
  - `:completed` - Always 0 (cannot detect from ps)
  - `:failed` - Count of stopped/zombie processes
  - `:total` - Total process count

  ## Examples

      iex> processes = DashboardPhoenix.ProcessMonitor.list_processes()
      iex> DashboardPhoenix.ProcessMonitor.get_stats(processes)
      %{running: 2, busy: 1, idle: 1, completed: 0, failed: 0, total: 2}

  """
  @spec get_stats([map()]) :: map()
  def get_stats(processes) do
    busy = Enum.count(processes, &(&1.status == Status.busy()))
    idle = Enum.count(processes, &(&1.status == Status.idle()))
    stopped = Enum.count(processes, &(&1.status in Status.inactive_statuses()))

    %{
      # Total active
      running: busy + idle,
      busy: busy,
      idle: idle,
      # We can't detect completed from ps
      completed: 0,
      failed: stopped,
      total: length(processes)
    }
  end
end
