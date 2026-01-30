defmodule DashboardPhoenix.ProcessMonitor do
  @moduledoc """
  Fetches real process data from the system.
  """

  @interesting_patterns ~w(opencode openclaw-tui openclaw-gateway)

  def list_processes do
    {output, 0} = System.cmd("ps", ["aux", "--sort=-pcpu"])
    
    output
    |> String.split("\n")
    |> Enum.drop(1)  # Skip header
    |> Enum.filter(&interesting_process?/1)
    |> Enum.take(20)  # Limit to 20 processes
    |> Enum.map(&parse_process_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp interesting_process?(line) do
    line_lower = String.downcase(line)
    Enum.any?(@interesting_patterns, &String.contains?(line_lower, &1))
  end

  defp parse_process_line(line) do
    parts = String.split(line, ~r/\s+/, parts: 11)
    
    case parts do
      [_user, pid, cpu, _mem, _vsz, rss, _tty, stat, start, time, command | _] ->
        cpu_float = parse_cpu(cpu)
        %{
          name: generate_name(pid),
          pid: pid,
          status: derive_status(stat, cpu_float),
          time: time,
          command: truncate_command(command),
          directory: extract_directory(command),
          details: command,
          cpu_usage: "#{cpu}%",
          memory_usage: format_memory(rss),
          model: detect_model(command),
          tokens: %{input: 0, output: 0, total: 0},
          exit_code: nil,
          last_output: nil,
          runtime: time,
          start_time: start
        }
      _ ->
        nil
    end
  end
  
  defp parse_cpu(cpu_str) do
    case Float.parse(cpu_str) do
      {val, _} -> val
      :error -> 0.0
    end
  end
  
  # Derive meaningful status from Unix state + CPU usage
  defp derive_status(stat, cpu) do
    cond do
      String.contains?(stat, "Z") -> "zombie"    # Zombie process
      String.contains?(stat, "T") -> "stopped"   # Stopped by signal
      String.contains?(stat, "X") -> "dead"      # Dead
      String.contains?(stat, "R") -> "busy"      # Actually running on CPU
      String.contains?(stat, ["S", "D"]) and cpu > 5.0 -> "busy"   # Sleeping but was recently active
      String.contains?(stat, ["S", "D"]) -> "idle"  # Sleeping, low CPU = waiting for input
      true -> "running"
    end
  end

  defp generate_name(pid) do
    # Generate a consistent name from PID using adjective-noun pattern
    adjectives = ~w(swift calm bold keen warm cool soft loud fast slow wild mild dark pale deep)
    nouns = ~w(beam node code wave pulse spark flame storm cloud river stone forge)
    
    pid_int = String.to_integer(pid)
    adj = Enum.at(adjectives, rem(pid_int, length(adjectives)))
    noun = Enum.at(nouns, rem(div(pid_int, 100), length(nouns)))
    "#{adj}-#{noun}"
  end

  defp truncate_command(command) do
    command
    |> String.slice(0, 80)
    |> String.replace(~r/--[a-zA-Z]+=\S+/, "")  # Remove long flags
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp extract_directory(command) do
    cond do
      String.contains?(command, "dashboard_phoenix") -> "/home/martins/clawd/dashboard_phoenix"
      String.contains?(command, "/home/martins/clawd") -> "/home/martins/clawd"
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

  defp format_memory(rss_kb) do
    case Integer.parse(rss_kb) do
      {kb, _} when kb >= 1_000_000 -> "#{Float.round(kb / 1_000_000, 1)} GB"
      {kb, _} when kb >= 1_000 -> "#{Float.round(kb / 1_000, 1)} MB"
      {kb, _} -> "#{kb} KB"
      :error -> "N/A"
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
