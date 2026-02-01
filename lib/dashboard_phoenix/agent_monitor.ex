defmodule DashboardPhoenix.AgentMonitor do
  @moduledoc """
  Monitors coding agent processes (Claude Code, OpenCode, Codex, etc.)
  by scanning running processes and extracting their status.
  """

  require Logger

  alias DashboardPhoenix.{CLITools, ProcessParser}

  @agent_patterns ~w(claude opencode codex pi\ coding)
  @cli_timeout_ms 10_000

  @doc """
  List all active coding agent sessions.
  """
  def list_active_agents do
    ProcessParser.list_processes(
      sort: "-start_time",
      filter: &is_agent_process?/1,
      limit: 10,
      timeout: @cli_timeout_ms
    )
    |> Enum.map(&transform_to_agent/1)
  end

  defp is_agent_process?(line) do
    ProcessParser.contains_patterns?(line, @agent_patterns) and
      not String.contains?(String.downcase(line), "grep") and
      not String.contains?(String.downcase(line), "ps aux")
  end

  defp transform_to_agent(%{pid: pid, cpu: cpu, mem: mem, stat: stat, start: start, 
                           time: time, command: command}) do
    agent_type = detect_agent_type(command)
    %{
      id: "agent-#{pid}",
      pid: pid,
      name: ProcessParser.generate_name(pid),
      status: ProcessParser.derive_status(stat, cpu),
      agent_type: agent_type,
      command: extract_task(command),
      cpu: "#{cpu}%",
      memory: "#{mem}%",
      start_time: start,
      runtime: time,
      current_action: nil,
      last_output: get_recent_output(pid, agent_type)
    }
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
    case CLITools.run_if_available("sh", ["-c", "ls -la /proc/#{pid}/fd/ 2>/dev/null | grep pts"], 
           timeout: 5_000, friendly_name: "Shell") do
      {:ok, output} when output != "" ->
        "Running on PTY"
      {:error, {:tool_not_available, _}} ->
        nil
      _ ->
        nil
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
