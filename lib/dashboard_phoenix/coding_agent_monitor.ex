defmodule DashboardPhoenix.CodingAgentMonitor do
  @moduledoc """
  Monitors and manages active coding agent processes.

  Detects running instances of AI coding assistants such as:
  - OpenCode
  - Claude Code
  - Codex
  - Aider

  Provides capabilities to:
  - List active agents with details (PID, resource usage, working directory).
  - Terminate specific agent processes safely.
  - Enrich process data with project context (e.g., extracting project name from CWD).
  """

  require Logger

  alias DashboardPhoenix.{CLITools, Status}

  @agent_patterns ~w(opencode claude-code codex aider)
  @cli_timeout_ms 10_000

  def list_agents do
    case CLITools.run_if_available("ps", ["aux"], timeout: @cli_timeout_ms, friendly_name: "ps command") do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.drop(1)  # Skip header
        |> Enum.map(&parse_process_line/1)
        |> Enum.filter(&is_coding_agent?/1)
        |> Enum.map(&enrich_agent/1)

      {:error, {:tool_not_available, message}} ->
        Logger.info("Cannot list coding agents - ps command not available: #{message}")
        []

      {:error, reason} ->
        Logger.warning("Failed to list coding agents: #{inspect(reason)}")
        []
    end
  end

  def kill_agent(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {pid_int, ""} -> kill_agent(pid_int)
      _ -> {:error, "Invalid PID"}
    end
  end

  def kill_agent(pid) when is_integer(pid) do
    case CLITools.run_if_available("kill", ["-15", to_string(pid)], 
         timeout: 5_000, friendly_name: "kill command") do
      {:ok, _} -> :ok
      {:error, {:tool_not_available, message}} -> {:error, message}
      {:error, {:exit, _code, error}} -> {:error, error}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp parse_process_line(line) do
    parts = String.split(line, ~r/\s+/, parts: 11)
    
    case parts do
      [user, pid, cpu, mem, _vsz, _rss, _tty, stat, start, time | cmd_parts] ->
        %{
          user: user,
          pid: pid,
          cpu: parse_float(cpu),
          memory: parse_float(mem),
          status: stat,
          started: start,
          time: time,
          command: Enum.join(cmd_parts, " ")
        }
      _ ->
        nil
    end
  end

  defp is_coding_agent?(nil), do: false
  defp is_coding_agent?(%{command: cmd}) do
    cmd_lower = String.downcase(cmd)
    Enum.any?(@agent_patterns, &String.contains?(cmd_lower, &1))
  end

  defp enrich_agent(proc) do
    agent_type = detect_agent_type(proc.command)
    working_dir = get_working_dir(proc.pid)
    
    %{
      pid: proc.pid,
      type: agent_type,
      cpu: proc.cpu,
      memory: proc.memory,
      status: humanize_status(proc.status),
      started: proc.started,
      runtime: proc.time,
      working_dir: working_dir,
      project: extract_project_name(working_dir),
      command: String.slice(proc.command, 0, 100)
    }
  end

  defp detect_agent_type(cmd) do
    cmd_lower = String.downcase(cmd)
    cond do
      String.contains?(cmd_lower, "opencode") -> "OpenCode"
      String.contains?(cmd_lower, "claude") -> "Claude Code"
      String.contains?(cmd_lower, "codex") -> "Codex"
      String.contains?(cmd_lower, "aider") -> "Aider"
      true -> "Unknown"
    end
  end

  defp get_working_dir(pid) do
    case File.read_link("/proc/#{pid}/cwd") do
      {:ok, path} -> path
      _ -> nil
    end
  end

  defp extract_project_name(nil), do: nil
  defp extract_project_name(path) do
    path |> Path.basename()
  end

  defp humanize_status(stat) do
    case String.first(stat || "?") do
      "R" -> Status.running()
      "S" -> "sleeping"
      "D" -> "waiting"
      "Z" -> Status.zombie()
      "T" -> Status.stopped()
      _ -> "unknown"
    end
  end

  defp parse_float(str) do
    case Float.parse(str || "0") do
      {f, _} -> f
      :error -> 0.0
    end
  end
end
