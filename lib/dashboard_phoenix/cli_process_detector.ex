defmodule DashboardPhoenix.CliProcessDetector do
  @moduledoc """
  Detects running CLI coding agent processes (OpenCode, Gemini CLI).
  Scans system processes to find agents started outside the dashboard.
  """

  alias DashboardPhoenix.Status

  @doc """
  Detects running OpenCode and Gemini CLI processes.
  Returns a list of process info maps.
  """
  def detect_processes do
    detect_opencode_processes() ++ detect_gemini_processes()
  end

  defp detect_opencode_processes do
    case System.cmd("pgrep", ["-af", "opencode run"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_opencode_process/1)
        |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  defp detect_gemini_processes do
    case System.cmd("pgrep", ["-af", "gemini.*Ticket"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.map(&parse_gemini_process/1)
        |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  defp parse_opencode_process(line) do
    # Format: "PID opencode run 'task description...'"
    case Regex.run(~r/^(\d+)\s+.*opencode\s+run\s+(.+)$/, line) do
      [_, pid, task] ->
        %{
          id: "opencode-cli-#{pid}",
          type: "opencode",
          name: extract_ticket_name(task) || "OpenCode ##{pid}",
          task: String.slice(task, 0, 100),
          status: Status.running(),
          pid: String.to_integer(pid),
          runtime: nil,
          start_time: nil
        }
      _ -> nil
    end
  end

  defp parse_gemini_process(line) do
    # Format: "PID node .../gemini 'task description...'"
    case Regex.run(~r/^(\d+)\s+.*gemini\s+(.+)$/, line) do
      [_, pid, task] ->
        %{
          id: "gemini-cli-#{pid}",
          type: "gemini",
          name: extract_ticket_name(task) || "Gemini ##{pid}",
          task: String.slice(task, 0, 100),
          status: Status.running(),
          pid: String.to_integer(pid),
          runtime: nil,
          start_time: nil
        }
      _ -> nil
    end
  end

  defp extract_ticket_name(text) do
    case Regex.run(~r/Ticket\s*#?(\d+)/i, text) do
      [_, num] -> "Ticket ##{num}"
      _ -> nil
    end
  end
end
