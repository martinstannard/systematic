defmodule DashboardPhoenix.AgentMonitor do
  @moduledoc """
  Monitors coding agent processes (Claude Code, OpenCode, Codex, etc.)
  by scanning running processes and extracting their status.
  """

  require Logger

  alias DashboardPhoenix.CommandRunner

  @agent_patterns ~w(claude opencode codex pi\ coding)
  @cli_timeout_ms 10_000

  @doc """
  List all active coding agent sessions.
  """
  def list_active_agents do
    find_agent_processes()
  end

  defp find_agent_processes do
    case CommandRunner.run("ps", ["aux", "--sort=-start_time"], timeout: @cli_timeout_ms) do
      {:ok, output} ->
        output
        |> String.split("\n")
        |> Enum.drop(1)
        |> Enum.filter(&is_agent_process?/1)
        |> Enum.map(&parse_agent_process/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(10)

      {:error, reason} ->
        Logger.warning("Failed to list agent processes: #{inspect(reason)}")
        []
    end
  end

  defp is_agent_process?(line) do
    line_lower = String.downcase(line)
    Enum.any?(@agent_patterns, &String.contains?(line_lower, &1)) and
      not String.contains?(line_lower, "grep") and
      not String.contains?(line_lower, "ps aux")
  end

  defp parse_agent_process(line) do
    parts = String.split(line, ~r/\s+/, parts: 11)
    
    case parts do
      [_user, pid, cpu, mem, _vsz, _rss, _tty, stat, start, time, command | _] ->
        agent_type = detect_agent_type(command)
        %{
          id: "agent-#{pid}",
          pid: pid,
          name: generate_session_name(pid),
          status: derive_status(stat, parse_float(cpu)),
          agent_type: agent_type,
          command: extract_task(command),
          cpu: "#{cpu}%",
          memory: "#{mem}%",
          start_time: start,
          runtime: time,
          current_action: nil,
          last_output: get_recent_output(pid, agent_type)
        }
      _ ->
        nil
    end
  end

  defp detect_agent_type(command) do
    cmd_lower = String.downcase(command)
    cond do
      String.contains?(cmd_lower, "claude") -> "claude"
      String.contains?(cmd_lower, "opencode") -> "opencode"
      String.contains?(cmd_lower, "codex") -> "codex"
      String.contains?(cmd_lower, "pi ") -> "pi"
      true -> "unknown"
    end
  end

  defp extract_task(command) do
    # Try to extract the prompt/task from the command
    cond do
      String.contains?(command, "\"") ->
        case Regex.run(~r/"([^"]{1,100})"/, command) do
          [_, task] -> truncate(task, 80)
          _ -> truncate(command, 80)
        end
      String.contains?(command, "'") ->
        case Regex.run(~r/'([^']{1,100})'/, command) do
          [_, task] -> truncate(task, 80)
          _ -> truncate(command, 80)
        end
      true ->
        truncate(command, 80)
    end
  end

  defp get_recent_output(pid, agent_type) do
    # Try to get recent terminal output for this process
    # This is a best-effort approach using /proc filesystem
    case File.read("/proc/#{pid}/fd/1") do
      {:ok, content} -> 
        content |> String.split("\n") |> Enum.take(-5) |> Enum.join("\n") |> truncate(200)
      {:error, _} -> 
        get_output_from_pty(pid, agent_type)
    end
  end

  defp get_output_from_pty(pid, _agent_type) do
    # Try to find associated PTY and read recent output
    case CommandRunner.run("sh", ["-c", "ls -la /proc/#{pid}/fd/ 2>/dev/null | grep pts"], 
           timeout: 5_000) do
      {:ok, output} when output != "" ->
        "Running on PTY"
      _ ->
        nil
    end
  end

  defp derive_status(stat, cpu) do
    cond do
      String.contains?(stat, "Z") -> "zombie"
      String.contains?(stat, "T") -> "stopped"
      String.contains?(stat, "R") -> "running"
      String.contains?(stat, ["S", "D"]) and cpu > 5.0 -> "running"
      String.contains?(stat, ["S", "D"]) -> "idle"
      true -> "running"
    end
  end

  defp generate_session_name(pid) do
    adjectives = ~w(swift calm bold keen warm cool soft loud fast slow wild mild dark pale deep)
    nouns = ~w(claw beam node wave pulse spark flame storm cloud river stone)
    
    pid_int = String.to_integer(pid)
    adj = Enum.at(adjectives, rem(pid_int, length(adjectives)))
    noun = Enum.at(nouns, rem(div(pid_int, 100), length(nouns)))
    "#{adj}-#{noun}"
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> 0.0
    end
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end
end
