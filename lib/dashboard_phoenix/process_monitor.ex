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

  alias DashboardPhoenix.{ProcessParser, Paths}

  @interesting_patterns ~w(opencode openclaw-tui openclaw-gateway)

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

  defp transform_to_dashboard_process(%{pid: pid, cpu: cpu, stat: stat, time: time, 
                                        command: command, rss: rss, start: start}) do
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

  def get_stats(processes) do
    busy = Enum.count(processes, &(&1.status == "busy"))
    idle = Enum.count(processes, &(&1.status == "idle"))
    stopped = Enum.count(processes, &(&1.status in ["stopped", "zombie", "dead"]))
    
    %{
      running: busy + idle,  # Total active
      busy: busy,
      idle: idle,
      completed: 0,  # We can't detect completed from ps
      failed: stopped,
      total: length(processes)
    }
  end
end
