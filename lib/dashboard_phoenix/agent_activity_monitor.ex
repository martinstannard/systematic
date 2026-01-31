defmodule DashboardPhoenix.AgentActivityMonitor do
  @moduledoc """
  Monitors coding agent activity by parsing session transcripts.
  Watches OpenClaw sessions, Claude Code, OpenCode, and Codex.
  """
  use GenServer

  require Logger

  alias DashboardPhoenix.{CommandRunner, Paths, ProcessParser}

  @poll_interval 1_000  # 1 second for responsive updates
  @max_recent_actions 10
  @cli_timeout_ms 10_000

  defp openclaw_sessions_dir, do: Paths.openclaw_sessions_dir()

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Get current activity for all monitored agents.
  Returns a list of agent activity maps.
  """
  def get_activity do
    GenServer.call(__MODULE__, :get_activity)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_activity")
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    schedule_poll()
    {:ok, %{
      agents: %{},
      session_offsets: %{},  # Track file offsets for incremental reading
      last_poll: nil
    }}
  end

  @impl true
  def handle_call(:get_activity, _from, state) do
    activities = state.agents
    |> Map.values()
    |> Enum.sort_by(& &1.last_activity, {:desc, DateTime})
    
    {:reply, activities, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = poll_agent_activity(state)
    schedule_poll()
    {:noreply, new_state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp poll_agent_activity(state) do
    # Combine multiple sources
    openclaw_agents = parse_openclaw_sessions(state)
    process_agents = find_coding_agent_processes()
    
    # Merge agent info - prefer session data but add process info
    merged = merge_agent_info(openclaw_agents, process_agents, state.agents)
    
    # Broadcast if there are changes
    if merged != state.agents do
      broadcast_activity(merged)
    end
    
    %{state | agents: merged, last_poll: System.system_time(:millisecond)}
  end

  defp parse_openclaw_sessions(state) do
    sessions_dir = openclaw_sessions_dir()
    case File.ls(sessions_dir) do
      {:ok, files} ->
        # Get the most recent sessions (modified in last 30 minutes)
        cutoff = System.system_time(:second) - 30 * 60
        
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn file ->
          path = Path.join(sessions_dir, file)
          case File.stat(path) do
            {:ok, %{mtime: mtime}} ->
              epoch = mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
              if epoch > cutoff, do: {path, file, epoch}, else: nil
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_, _, epoch} -> epoch end, :desc)
        |> Enum.take(5)  # Monitor top 5 most recent sessions
        |> Enum.map(fn {path, file, _} -> parse_session_file(path, file, state.session_offsets) end)
        |> Enum.reject(&is_nil/1)
        |> Map.new(fn agent -> {agent.id, agent} end)
      _ ->
        %{}
    end
  end

  defp parse_session_file(path, filename, _offsets) do
    # Read the last portion of the file (tail approach)
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: true)
        events = lines
        |> Enum.map(&parse_jsonl_line/1)
        |> Enum.reject(&is_nil/1)
        
        extract_agent_activity(events, filename)
      _ ->
        nil
    end
  end

  defp parse_jsonl_line(line) do
    case Jason.decode(line) do
      {:ok, data} -> data
      _ -> nil
    end
  end

  defp extract_agent_activity(events, filename) do
    # Find session info
    session_event = Enum.find(events, & &1["type"] == "session")
    session_id = if session_event, do: session_event["id"], else: String.replace(filename, ".jsonl", "")
    cwd = if session_event, do: session_event["cwd"], else: nil
    
    # Find model info
    model_event = Enum.find(events, & &1["type"] == "model_change")
    model = if model_event, do: model_event["modelId"], else: "unknown"
    
    # Extract recent tool calls
    tool_calls = events
    |> Enum.filter(fn e -> 
      e["type"] == "message" and 
      e["message"]["role"] == "assistant" and
      is_list(e["message"]["content"])
    end)
    |> Enum.flat_map(fn e ->
      e["message"]["content"]
      |> Enum.filter(& is_map(&1) and &1["type"] == "toolCall")
      |> Enum.map(fn tc ->
        %{
          name: tc["name"],
          arguments: tc["arguments"],
          timestamp: e["timestamp"]
        }
      end)
    end)
    |> Enum.take(-@max_recent_actions)
    
    # Get last action
    last_action = List.last(tool_calls)
    
    # Extract files being worked on from tool calls
    files_worked = tool_calls
    |> Enum.flat_map(&extract_files_from_tool_call/1)
    |> Enum.uniq()
    |> Enum.take(-10)
    
    # Determine status
    last_message = events
    |> Enum.filter(& &1["type"] == "message")
    |> List.last()
    
    status = determine_status(last_message, tool_calls)
    
    # Get the last activity timestamp
    last_activity = cond do
      last_action && last_action.timestamp ->
        parse_timestamp(last_action.timestamp)
      last_message && last_message["timestamp"] ->
        parse_timestamp(last_message["timestamp"])
      true ->
        DateTime.utc_now()
    end
    
    %{
      id: "openclaw-#{session_id}",
      session_id: session_id,
      type: :openclaw,
      model: model,
      cwd: cwd,
      status: status,
      last_action: format_action(last_action),
      recent_actions: Enum.map(tool_calls, &format_action/1),
      files_worked: files_worked,
      last_activity: last_activity,
      tool_call_count: length(tool_calls)
    }
  end

  defp extract_files_from_tool_call(%{name: name, arguments: args}) when is_map(args) do
    cond do
      name in ["Read", "read"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["Write", "write"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["Edit", "edit"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["exec", "Bash"] -> extract_files_from_command(args["command"] || "")
      true -> []
    end
  end
  defp extract_files_from_tool_call(_), do: []

  defp extract_files_from_command(command) when is_binary(command) do
    # Extract file paths from common commands
    Regex.scan(~r{(?:^|\s)([~/.][\w./\-]+\.\w+)}, command)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.take(5)
  end
  defp extract_files_from_command(_), do: []

  defp determine_status(last_message, tool_calls) do
    cond do
      is_nil(last_message) -> "idle"
      last_message["message"]["role"] == "assistant" and 
        has_pending_tool_calls?(last_message) -> "executing"
      last_message["message"]["role"] == "toolResult" -> "thinking"
      last_message["message"]["role"] == "user" -> "processing"
      length(tool_calls) == 0 -> "idle"
      true -> "active"
    end
  end

  defp has_pending_tool_calls?(message) do
    content = message["message"]["content"] || []
    Enum.any?(content, & is_map(&1) and &1["type"] == "toolCall")
  end

  defp format_action(nil), do: nil
  defp format_action(%{name: name, arguments: args, timestamp: ts}) do
    target = cond do
      is_map(args) and args["path"] -> truncate(args["path"], 50)
      is_map(args) and args["file_path"] -> truncate(args["file_path"], 50)
      is_map(args) and args["command"] -> truncate(args["command"], 50)
      true -> nil
    end
    
    %{
      action: name,
      target: target,
      timestamp: parse_timestamp(ts)
    }
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts, :millisecond)
  end
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp find_coding_agent_processes do
    ProcessParser.list_processes(
      sort: "-start_time",
      filter: &coding_agent_process?/1,
      timeout: @cli_timeout_ms
    )
    |> Enum.map(&transform_process_to_agent/1)
    |> Map.new(fn a -> {a.id, a} end)
  end

  defp coding_agent_process?(line) do
    ProcessParser.contains_patterns?(line, ~w(claude opencode codex)) and
    not String.contains?(String.downcase(line), "grep") and
    not String.contains?(String.downcase(line), "ps aux")
  end

  defp transform_process_to_agent(%{pid: pid, cpu: cpu, mem: mem, start: start, command: command}) do
    type = detect_agent_type(command)
    cwd = get_process_cwd(pid)
    
    %{
      id: "process-#{pid}",
      session_id: pid,
      type: type,
      model: detect_model_from_command(command),
      cwd: cwd,
      status: if(cpu > 5.0, do: "busy", else: "idle"),
      last_action: nil,
      recent_actions: [],
      files_worked: get_recently_modified_files(cwd),
      last_activity: DateTime.utc_now(),
      cpu: "#{cpu}%",
      memory: "#{mem}%",
      start_time: start,
      tool_call_count: 0
    }
  end

  defp detect_agent_type(command) do
    cmd_lower = String.downcase(command)
    cond do
      String.contains?(cmd_lower, "claude") -> :claude_code
      String.contains?(cmd_lower, "opencode") -> :opencode
      String.contains?(cmd_lower, "codex") -> :codex
      true -> :unknown
    end
  end

  defp detect_model_from_command(command) do
    cond do
      String.contains?(command, "opus") -> "claude-opus"
      String.contains?(command, "sonnet") -> "claude-sonnet"
      String.contains?(command, "gemini") -> "gemini"
      true -> "unknown"
    end
  end

  defp get_process_cwd(pid) do
    case File.read_link("/proc/#{pid}/cwd") do
      {:ok, cwd} -> cwd
      _ -> nil
    end
  end

  defp get_recently_modified_files(nil), do: []
  defp get_recently_modified_files(cwd) do
    case CommandRunner.run("find", [cwd, "-maxdepth", "3", "-type", "f", "-mmin", "-5", 
                             "-name", "*.ex", "-o", "-name", "*.exs", 
                             "-o", "-name", "*.ts", "-o", "-name", "*.js",
                             "-o", "-name", "*.py", "-o", "-name", "*.rb"], 
                    timeout: @cli_timeout_ms) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.take(10)
        
      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  defp merge_agent_info(openclaw_agents, process_agents, _existing) do
    # Prefer OpenClaw session data, supplement with process info
    Map.merge(process_agents, openclaw_agents)
  end

  defp broadcast_activity(agents) do
    activities = agents |> Map.values() |> Enum.sort_by(& &1.last_activity, {:desc, DateTime})
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "agent_activity", {:agent_activity, activities})
  end

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end
  defp truncate(_, _), do: ""

end
