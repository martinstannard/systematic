defmodule DashboardPhoenix.SessionBridge do
  @moduledoc """
  Bridges sub-agent progress to the dashboard.
  Tails JSONL progress files written by sub-agents.
  """
  use GenServer

  alias DashboardPhoenix.Paths
  alias DashboardPhoenix.FileUtils
  
  @default_progress_file "/tmp/agent-progress.jsonl"
  @poll_interval 500  # 500ms for snappy updates
  @max_progress_events 100

  defp progress_file do
    Application.get_env(:dashboard_phoenix, :progress_file, @default_progress_file)
  end

  defp sessions_file do
    Application.get_env(:dashboard_phoenix, :sessions_file) || Paths.sessions_file()
  end

  defp transcripts_dir do
    Paths.openclaw_sessions_dir()
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_sessions do
    GenServer.call(__MODULE__, :get_sessions)
  end

  def get_progress do
    GenServer.call(__MODULE__, :get_progress)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    # Ensure progress file exists (don't overwrite sessions - it's managed by OpenClaw)
    FileUtils.ensure_exists(progress_file())
    
    schedule_poll()
    {:ok, %{
      sessions: [],
      progress: [],
      progress_offset: 0,
      last_session_mtime: nil,
      transcript_offsets: %{},  # Track read positions per transcript file
      last_transcript_poll: 0
    }}
  end

  @impl true
  def handle_call(:get_sessions, _from, state) do
    {:reply, state.sessions, state}
  end

  @impl true
  def handle_call(:get_progress, _from, state) do
    {:reply, state.progress, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = state
    |> poll_progress()
    |> poll_transcripts()
    |> poll_sessions()
    
    schedule_poll()
    {:noreply, new_state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  # Tail the JSONL progress file for new lines
  defp poll_progress(state) do
    case File.stat(progress_file()) do
      {:ok, %{size: size}} when size > state.progress_offset ->
        case File.open(progress_file(), [:read]) do
          {:ok, file} ->
            :file.position(file, state.progress_offset)
            new_lines = IO.read(file, :eof)
            File.close(file)
            
            new_events = parse_progress_lines(new_lines)
            
            if new_events != [] do
              # Keep last 100 events
              updated_progress = (state.progress ++ new_events) |> Enum.take(-100)
              broadcast_progress(new_events)
              %{state | progress: updated_progress, progress_offset: size}
            else
              %{state | progress_offset: size}
            end
          {:error, _} ->
            state
        end
      _ ->
        state
    end
  end

  defp parse_progress_lines(data) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_progress_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_progress_line(line) do
    case Jason.decode(line) do
      {:ok, event} -> normalize_event(event)
      {:error, _} -> nil
    end
  end

  defp normalize_event(e) do
    %{
      ts: e["ts"] || System.system_time(:millisecond),
      agent: e["agent"] || "unknown",
      action: e["action"] || "unknown",
      target: e["target"] || "",
      status: e["status"] || "running",
      output: e["output"] || "",
      details: e["details"] || ""
    }
  end

  # Poll recent transcripts for tool calls (Live Progress)
  defp poll_transcripts(state) do
    now = System.system_time(:millisecond)
    # Only poll transcripts every 500ms to reduce overhead
    if now - state.last_transcript_poll < 500 do
      state
    else
      do_poll_transcripts(%{state | last_transcript_poll: now})
    end
  end

  defp do_poll_transcripts(state) do
    dir = transcripts_dir()
    case File.ls(dir) do
      {:ok, files} ->
        cutoff = System.system_time(:second) - 600  # Last 10 minutes
        
        recent_files = files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.reject(&(&1 == "sessions.json"))
        |> Enum.map(fn file ->
          path = Path.join(dir, file)
          case File.stat(path) do
            {:ok, %{mtime: mtime, size: size}} ->
              epoch = mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
              if epoch > cutoff, do: {path, file, size}, else: nil
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_, _, size} -> size end, :desc)
        |> Enum.take(5)  # Top 5 most recent/active
        
        # Extract new tool calls from each file
        {new_events, new_offsets} = 
          Enum.reduce(recent_files, {[], state.transcript_offsets}, fn {path, file, _size}, {events_acc, offsets_acc} ->
            offset = Map.get(offsets_acc, file, 0)
            {new_events, new_offset} = extract_tool_calls_from_transcript(path, file, offset)
            {events_acc ++ new_events, Map.put(offsets_acc, file, new_offset)}
          end)
        
        if new_events != [] do
          # Merge and deduplicate by timestamp
          updated_progress = (state.progress ++ new_events)
          |> Enum.uniq_by(& &1.ts)
          |> Enum.sort_by(& &1.ts)
          |> Enum.take(-@max_progress_events)
          
          broadcast_progress(new_events)
          %{state | progress: updated_progress, transcript_offsets: new_offsets}
        else
          %{state | transcript_offsets: new_offsets}
        end
        
      _ ->
        state
    end
  end

  defp extract_tool_calls_from_transcript(path, filename, offset) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > offset ->
        case File.open(path, [:read]) do
          {:ok, file} ->
            :file.position(file, offset)
            content = IO.read(file, :eof)
            File.close(file)
            
            # Extract session label from sessions.json if available
            session_id = String.replace(filename, ".jsonl", "")
            agent_label = get_session_label(session_id)
            
            # Parse all lines, collecting tool calls and results
            lines = String.split(content, "\n", trim: true)
            {tool_calls, tool_results} = parse_tool_calls_and_results(lines, agent_label)
            
            # Merge results into their corresponding tool calls
            events = merge_tool_results(tool_calls, tool_results)
            
            {events, size}
          _ ->
            {[], offset}
        end
      _ ->
        {[], offset}
    end
  end

  # Parse both tool calls and tool results in one pass
  defp parse_tool_calls_and_results(lines, agent_label) do
    Enum.reduce(lines, {[], %{}}, fn line, {calls_acc, results_acc} ->
      case Jason.decode(line) do
        {:ok, %{"type" => "message", "message" => %{"role" => "assistant", "content" => content}, "timestamp" => ts}} 
          when is_list(content) ->
          new_calls = content
          |> Enum.filter(& is_map(&1) and &1["type"] == "toolCall")
          |> Enum.map(fn tc ->
            args = tc["arguments"] || %{}
            target = args["path"] || args["file_path"] || args["command"] || args["query"] || ""
            %{
              ts: ts,
              tool_call_id: tc["id"],
              agent: agent_label,
              action: tc["name"] || "unknown",
              target: truncate_target(target),
              status: "running",
              output: "",
              output_summary: "",
              details: ""
            }
          end)
          {calls_acc ++ new_calls, results_acc}
        
        {:ok, %{"type" => "message", "message" => %{"role" => "toolResult", "toolCallId" => tool_call_id} = msg}} ->
          result = extract_tool_result(msg)
          {calls_acc, Map.put(results_acc, tool_call_id, result)}
        
        _ ->
          {calls_acc, results_acc}
      end
    end)
  end

  # Extract useful info from a tool result message
  defp extract_tool_result(msg) do
    content = msg["content"] || []
    details = msg["details"] || %{}
    is_error = msg["isError"] || false
    tool_name = msg["toolName"] || ""
    
    # Get the text content
    text = case content do
      [%{"type" => "text", "text" => t} | _] -> t
      _ -> ""
    end
    
    # Use aggregated if available (for exec commands), otherwise use text
    output = details["aggregated"] || text || ""
    
    # Create a summary based on tool type
    summary = create_output_summary(tool_name, output, details, is_error)
    
    %{
      output: truncate_output(output),
      output_summary: summary,
      is_error: is_error,
      exit_code: details["exitCode"],
      duration_ms: details["durationMs"]
    }
  end

  # Create a short summary for the UI
  defp create_output_summary(tool_name, output, details, is_error) do
    cond do
      is_error -> "❌ Error"
      tool_name == "exec" ->
        exit_code = details["exitCode"]
        duration = details["durationMs"]
        lines = output |> String.split("\n") |> length()
        status = if exit_code == 0, do: "✓", else: "✗ exit #{exit_code}"
        "#{status} #{lines} lines" <> if(duration, do: " (#{duration}ms)", else: "")
      tool_name == "Read" ->
        lines = output |> String.split("\n") |> length()
        "📄 #{lines} lines"
      tool_name == "Write" ->
        "✓ written"
      tool_name == "Edit" ->
        "✓ edited"
      tool_name == "sessions_spawn" ->
        if String.contains?(output, "accepted"), do: "✓ spawned", else: "pending"
      String.length(output) > 0 ->
        "✓ #{String.length(output)} chars"
      true ->
        "✓ done"
    end
  end

  # Truncate output for storage/display (keep first ~500 chars)
  defp truncate_output(output) when is_binary(output) do
    if String.length(output) > 500 do
      String.slice(output, 0, 500) <> "..."
    else
      output
    end
  end
  defp truncate_output(_), do: ""

  # Merge tool results back into their corresponding tool calls
  defp merge_tool_results(tool_calls, tool_results) do
    Enum.map(tool_calls, fn call ->
      case Map.get(tool_results, call.tool_call_id) do
        nil -> 
          # No result yet - still running
          Map.delete(call, :tool_call_id)
        result ->
          call
          |> Map.merge(%{
            status: if(result.is_error, do: "error", else: "done"),
            output: result.output,
            output_summary: result.output_summary
          })
          |> Map.delete(:tool_call_id)
      end
    end)
  end

  defp get_session_label(session_id) do
    case File.read(sessions_file()) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, sessions_map} when is_map(sessions_map) ->
            sessions_map
            |> Enum.find(fn {_key, val} -> val["sessionId"] == session_id end)
            |> case do
              {key, val} -> 
                cond do
                  # Has explicit label
                  val["label"] && val["label"] != "" -> val["label"]
                  # Main session
                  String.contains?(key, ":main:main") -> "main"
                  # Cron job - extract name from key
                  String.contains?(key, ":cron:") -> "cron"
                  # Subagent without label
                  String.contains?(key, ":subagent:") -> "subagent"
                  # Fallback
                  true -> String.slice(session_id, 0, 8)
                end
              nil -> String.slice(session_id, 0, 8)
            end
          _ -> String.slice(session_id, 0, 8)
        end
      _ -> String.slice(session_id, 0, 8)
    end
  end

  defp truncate_target(target) when is_binary(target) do
    if String.length(target) > 80 do
      String.slice(target, 0, 77) <> "..."
    else
      target
    end
  end
  defp truncate_target(_), do: ""

  # Poll the OpenClaw sessions.json file
  defp poll_sessions(state) do
    case File.stat(sessions_file()) do
      {:ok, %{mtime: mtime}} when mtime != state.last_session_mtime ->
        case File.read(sessions_file()) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, sessions_map} when is_map(sessions_map) ->
                # OpenClaw format: %{"session:key" => %{...session data...}}
                normalized = 
                  sessions_map
                  |> Enum.map(fn {key, data} -> normalize_session(key, data) end)
                  |> Enum.filter(&filter_relevant_session/1)
                  |> Enum.sort_by(& &1.updated_at, :desc)
                  |> Enum.take(20)
                
                broadcast_sessions(normalized)
                %{state | sessions: normalized, last_session_mtime: mtime}
              _ ->
                state
            end
          {:error, _} ->
            state
        end
      _ ->
        state
    end
  end

  # Only show subagents and main session, not cron jobs
  defp filter_relevant_session(%{session_key: key}) do
    String.contains?(key, "subagent") || key == "agent:main:main"
  end

  defp normalize_session(key, s) do
    # Determine status based on recent activity
    updated_at = s["updatedAt"] || 0
    now = System.system_time(:millisecond)
    age_ms = now - updated_at
    
    status = cond do
      age_ms < 60_000 -> "running"      # Active in last minute
      age_ms < 300_000 -> "idle"        # Active in last 5 mins
      true -> "completed"
    end

    session_id = s["sessionId"] || key
    
    # Extract details from transcript for all sessions (running and completed)
    # Running sessions get live progress data, completed get final summary
    {task_summary, result_snippet, runtime, tokens_in, tokens_out, cost, time_info, current_action, recent_actions} = 
      extract_transcript_details(session_id, status)

    %{
      id: session_id,
      session_key: key,
      label: s["label"] || extract_label(key),
      status: status,
      channel: s["channel"] || "unknown",
      model: s["model"] || default_model(key),
      total_tokens: s["totalTokens"] || 0,
      context_tokens: s["contextTokens"] || 0,
      updated_at: updated_at,
      age: format_age(age_ms),
      transcript_path: s["transcriptPath"],
      # Details from transcript (works for both running and completed)
      task_summary: task_summary,
      result_snippet: result_snippet,
      runtime: runtime,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      cost: cost,
      completed_at: time_info,  # For completed: completion time, for running: start time
      current_action: current_action,  # What's happening right now (for running)
      recent_actions: recent_actions   # Last few tool calls (for running)
    }
  end

  # Extract details from transcript file for all sessions (running and completed)
  defp extract_transcript_details(session_id, status) do
    transcript_path = Path.join(transcripts_dir(), "#{session_id}.jsonl")
    
    case File.read(transcript_path) do
      {:ok, content} ->
        lines = String.split(content, "\n", trim: true)
        
        # Parse all lines
        parsed = Enum.map(lines, fn line ->
          case Jason.decode(line) do
            {:ok, data} -> data
            _ -> nil
          end
        end) |> Enum.reject(&is_nil/1)
        
        # Find first user message (task)
        task_summary = parsed
        |> Enum.find(fn entry ->
          entry["type"] == "message" && 
          get_in(entry, ["message", "role"]) == "user"
        end)
        |> case do
          nil -> nil
          entry -> 
            get_in(entry, ["message", "content"])
            |> extract_text_content()
            |> truncate_text(150)
        end
        
        # Find last assistant text message (result) - only for completed sessions
        result_snippet = if status == "completed" do
          parsed
          |> Enum.filter(fn entry ->
            entry["type"] == "message" && 
            get_in(entry, ["message", "role"]) == "assistant"
          end)
          |> List.last()
          |> case do
            nil -> nil
            entry ->
              get_in(entry, ["message", "content"])
              |> extract_text_content()
              |> truncate_text(100)
          end
        else
          nil
        end
        
        # Calculate runtime from first and last timestamps
        timestamps = parsed
        |> Enum.map(fn entry -> entry["timestamp"] end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&parse_timestamp/1)
        |> Enum.reject(&is_nil/1)
        
        {start_time, end_time} = case timestamps do
          [] -> {nil, nil}
          [single] -> {single, single}
          list -> {List.first(list), List.last(list)}
        end
        
        # For running sessions, calculate elapsed time from start to now
        # For completed sessions, calculate total runtime
        runtime = cond do
          status in ["running", "idle"] && start_time ->
            diff_ms = DateTime.diff(DateTime.utc_now(), start_time, :millisecond)
            format_runtime(diff_ms)
          start_time && end_time ->
            diff_ms = DateTime.diff(end_time, start_time, :millisecond)
            format_runtime(diff_ms)
          true ->
            nil
        end
        
        # Time info: for completed = completion time, for running = start time
        time_info = cond do
          status == "completed" && end_time ->
            Calendar.strftime(end_time, "%H:%M:%S")
          status in ["running", "idle"] && start_time ->
            Calendar.strftime(start_time, "%H:%M:%S")
          true ->
            nil
        end
        
        # Sum up token usage from all assistant messages
        {tokens_in, tokens_out, total_cost} = parsed
        |> Enum.filter(fn entry ->
          entry["type"] == "message" && 
          get_in(entry, ["message", "role"]) == "assistant" &&
          get_in(entry, ["message", "usage"]) != nil
        end)
        |> Enum.reduce({0, 0, 0.0}, fn entry, {in_acc, out_acc, cost_acc} ->
          usage = get_in(entry, ["message", "usage"]) || %{}
          input = (usage["input"] || 0) + (usage["cacheRead"] || 0)
          output = usage["output"] || 0
          cost = get_in(usage, ["cost", "total"]) || 0
          {in_acc + input, out_acc + output, cost_acc + cost}
        end)
        
        # For running sessions, extract current action and recent tool calls
        {current_action, recent_actions} = if status in ["running", "idle"] do
          extract_running_session_status(parsed)
        else
          {nil, []}
        end
        
        {task_summary, result_snippet, runtime, tokens_in, tokens_out, total_cost, time_info, current_action, recent_actions}
        
      {:error, _} ->
        {nil, nil, nil, 0, 0, 0, nil, nil, []}
    end
  end
  
  # Extract current action and recent tool calls for running sessions
  defp extract_running_session_status(parsed) do
    # Get all tool calls from assistant messages
    tool_calls = parsed
    |> Enum.flat_map(fn entry ->
      if entry["type"] == "message" && get_in(entry, ["message", "role"]) == "assistant" do
        content = get_in(entry, ["message", "content"]) || []
        content
        |> Enum.filter(fn item -> is_map(item) && item["type"] == "toolCall" end)
        |> Enum.map(fn tc ->
          args = tc["arguments"] || %{}
          target = args["path"] || args["file_path"] || args["command"] || args["query"] || ""
          %{
            id: tc["id"],
            name: tc["name"] || "unknown",
            target: truncate_target(target)
          }
        end)
      else
        []
      end
    end)
    
    # Get all tool results
    tool_results = parsed
    |> Enum.filter(fn entry ->
      entry["type"] == "message" && get_in(entry, ["message", "role"]) == "toolResult"
    end)
    |> Enum.map(fn entry -> get_in(entry, ["message", "toolCallId"]) end)
    |> MapSet.new()
    
    # Find tool calls without results (currently running)
    pending_calls = Enum.reject(tool_calls, fn tc -> MapSet.member?(tool_results, tc.id) end)
    
    # Current action is the last pending tool call
    current_action = case List.last(pending_calls) do
      nil -> nil
      tc -> "#{tc.name}: #{tc.target}"
    end
    
    # Recent actions are the last 5 completed tool calls
    recent_actions = tool_calls
    |> Enum.filter(fn tc -> MapSet.member?(tool_results, tc.id) end)
    |> Enum.take(-5)
    |> Enum.map(fn tc -> "#{tc.name}: #{tc.target}" end)
    
    {current_action, recent_actions}
  end

  defp extract_text_content(content) when is_list(content) do
    content
    |> Enum.filter(fn item -> is_map(item) && item["type"] == "text" end)
    |> Enum.map(fn item -> item["text"] || "" end)
    |> Enum.join(" ")
  end
  defp extract_text_content(content) when is_binary(content), do: content
  defp extract_text_content(_), do: ""

  defp truncate_text(nil, _), do: nil
  defp truncate_text(text, max_len) when is_binary(text) do
    text = String.replace(text, ~r/\s+/, " ") |> String.trim()
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 3) <> "..."
    else
      text
    end
  end
  defp truncate_text(_, _), do: nil

  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
  defp parse_timestamp(ts) when is_integer(ts) do
    case DateTime.from_unix(ts, :millisecond) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end
  defp parse_timestamp(_), do: nil

  defp format_runtime(ms) when ms < 1000, do: "<1s"
  defp format_runtime(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"
  defp format_runtime(ms) when ms < 3_600_000 do
    mins = div(ms, 60_000)
    secs = div(rem(ms, 60_000), 1000)
    "#{mins}m #{secs}s"
  end
  defp format_runtime(ms) do
    hours = div(ms, 3_600_000)
    mins = div(rem(ms, 3_600_000), 60_000)
    "#{hours}h #{mins}m"
  end

  defp default_model(key) do
    cond do
      String.contains?(key, "main:main") -> "opus"
      String.contains?(key, "subagent") -> "sonnet"
      String.contains?(key, "cron") -> "sonnet"
      true -> "sonnet"
    end
  end

  defp extract_label(key) do
    key
    |> String.split(":")
    |> List.last()
    |> String.slice(0, 12)
  end

  defp format_age(ms) when ms < 1000, do: "just now"
  defp format_age(ms) when ms < 60_000, do: "#{div(ms, 1000)}s ago"
  defp format_age(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m ago"
  defp format_age(ms) when ms < 86_400_000, do: "#{div(ms, 3_600_000)}h ago"
  defp format_age(ms), do: "#{div(ms, 86_400_000)}d ago"

  defp broadcast_progress(events) do
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "agent_updates", {:progress, events})
  end

  defp broadcast_sessions(sessions) do
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "agent_updates", {:sessions, sessions})
  end
end
