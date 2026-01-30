defmodule DashboardPhoenix.AgentMonitor do
  @moduledoc """
  Monitors OpenClaw exec sessions (coding agents like OpenCode, Codex, Claude).
  Reads from a JSON file that gets updated by OpenClaw agent.
  """

  @sessions_file Path.expand("../../priv/agent_sessions.json", __DIR__)

  @doc """
  List all exec sessions with their current state from the JSON file.
  """
  def list_sessions do
    case File.read(@sessions_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"sessions" => sessions}} ->
            {:ok, Enum.map(sessions, &normalize_session/1)}
          {:ok, _} ->
            {:ok, []}
          {:error, _} ->
            {:ok, []}
        end
      {:error, _} ->
        {:ok, []}
    end
  end

  defp normalize_session(s) do
    %{
      id: s["id"],
      name: s["id"],
      status: s["status"],
      duration: s["duration"],
      command: s["command"],
      agent_type: s["agent_type"] || detect_agent_type(s["command"] || ""),
      current_action: parse_action(s["current_action"]),
      last_output: s["last_output"]
    }
  end
  
  defp parse_action(nil), do: nil
  defp parse_action(%{"action" => action, "target" => target}), do: %{action: action, target: target}
  defp parse_action(_), do: nil

  defp detect_agent_type(command) do
    cond do
      String.contains?(command, "opencode") -> "opencode"
      String.contains?(command, "codex") -> "codex"
      String.contains?(command, "claude") -> "claude"
      String.contains?(command, "pi ") -> "pi"
      true -> "shell"
    end
  end

  @doc """
  Get all running/completed sessions (filters out failed).
  """
  @spec list_active_agents() :: [map()]
  def list_active_agents do
    {:ok, sessions} = list_sessions()
    Enum.filter(sessions, &(&1.status in ["running", "completed"]))
  end
end
