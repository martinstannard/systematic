defmodule DashboardPhoenix.SessionBridge do
  @moduledoc """
  Bridges sub-agent progress to the dashboard.
  Tails JSONL progress files written by sub-agents.
  
  ## Performance Optimizations (Ticket #70)
  
  - Caches parsed sessions.json with mtime checking
  - Batches file stat calls during directory scans
  - Caches transcript details per session, re-parses only on mtime change
  - Single-pass file stat collection for cleanup operations
  """
  use GenServer

  alias DashboardPhoenix.Paths
  alias DashboardPhoenix.FileUtils
  
  @base_poll_interval 1000   # Start responsive at 1s 
  @max_poll_interval 2000    # Back off to 2s when idle
  @backoff_increment 250     # Increase by 250ms each idle poll
  @max_progress_events 100
  @max_transcript_offsets 50  # Limit transcript_offsets map size
  @transcript_cleanup_interval 300_000  # Clean up old transcripts every 5 minutes
  @directory_scan_cache_ttl 5000  # Cache directory listings for 5 seconds

  defp sessions_file do
    Paths.sessions_file()
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

  def get_state_metrics do
    GenServer.call(__MODULE__, :get_state_metrics)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    # Ensure progress file exists (don't overwrite sessions - it's managed by OpenClaw)
    FileUtils.ensure_exists(Paths.progress_file())
    
    schedule_poll(@base_poll_interval)
    schedule_transcript_cleanup()
    {:ok, %{
      sessions: [],
      progress: [],
      progress_offset: 0,
      last_session_mtime: nil,
      transcript_offsets: %{},  # Track read positions per transcript file
      last_transcript_poll: 0,
      current_poll_interval: @base_poll_interval,  # Adaptive polling interval
      last_cleanup: System.system_time(:millisecond),
      # Performance caches (Ticket #70)
      sessions_cache: %{parsed: nil, mtime: nil},  # Cached parsed sessions.json
      transcript_details_cache: %{},  # %{session_id => %{mtime: _, size: _, details: _}}
      directory_scan_cache: %{files: nil, timestamp: 0}  # Cache directory listings
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
  def handle_call(:get_state_metrics, _from, state) do
    metrics = %{
      sessions_count: length(state.sessions),
      progress_events: length(state.progress),
      transcript_offsets_count: map_size(state.transcript_offsets),
      last_cleanup: state.last_cleanup,
      progress_offset: state.progress_offset,
      current_poll_interval: state.current_poll_interval,
      memory_usage_mb: :erlang.memory(:total) / (1024 * 1024)
    }
    {:reply, metrics, state}
  end

  @impl true
  def handle_info(:poll, state) do
    # Track state before polling to detect changes
    old_progress_offset = state.progress_offset
    old_session_mtime = state.last_session_mtime
    old_transcript_offsets = state.transcript_offsets
    
    # Refresh sessions cache first (used by transcript polling)
    state = refresh_sessions_cache(state)
    
    new_state = state
    |> poll_progress()
    |> poll_transcripts()
    |> poll_sessions()
    
    # Check if any changes occurred
    changes_detected = 
      new_state.progress_offset != old_progress_offset ||
      new_state.last_session_mtime != old_session_mtime ||
      new_state.transcript_offsets != old_transcript_offsets
    
    # Adaptive polling: fast when active, back off when idle
    new_interval = if changes_detected do
      # Reset to fast polling when changes detected
      @base_poll_interval
    else
      # Gradually back off, capped at max interval
      min(new_state.current_poll_interval + @backoff_increment, @max_poll_interval)
    end
    
    new_state = %{new_state | current_poll_interval: new_interval}
    schedule_poll(new_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:cleanup_transcripts, state) do
    new_state = cleanup_old_transcript_offsets(state)
    schedule_transcript_cleanup()
    {:noreply, new_state}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp schedule_transcript_cleanup do
    Process.send_after(self(), :cleanup_transcripts, @transcript_cleanup_interval)
  end

  # Refresh sessions.json cache if mtime changed
  defp refresh_sessions_cache(state) do
    case File.stat(sessions_file()) do
      {:ok, %{mtime: mtime}} when mtime != state.sessions_cache.mtime ->
        case File.read(sessions_file()) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, sessions_map} when is_map(sessions_map) ->
                %{state | sessions_cache: %{parsed: sessions_map, mtime: mtime}}
              _ ->
                state
            end
          _ ->
            state
        end
      _ ->
        state
    end
  end

  # Clean up old transcript offsets to prevent unbounded memory growth
  # Optimized: Single pass file stat collection, reuse cached directory scan
  defp cleanup_old_transcript_offsets(state) do
    dir = transcripts_dir()
    cutoff = System.system_time(:second) - 3600  # Keep files from last hour
    
    {files, new_state} = get_cached_directory_files(state, dir)
    
    if files != [] do
      # Single pass: collect stats for all relevant files at once
      jsonl_files = files
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.reject(&(&1 == "sessions.json"))
      
      # Batch stat all files once
      file_stats = jsonl_files
      |> Enum.map(fn file ->
        path = Path.join(dir, file)
        case File.stat(path) do
          {:ok, %{mtime: mtime}} ->
            epoch = mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
            {file, epoch}
          _ -> 
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()
      
      # Filter to recent files using pre-collected stats
      active_files = file_stats
      |> Enum.filter(fn {_file, epoch} -> epoch > cutoff end)
      |> Enum.map(fn {file, _epoch} -> file end)
      |> MapSet.new()
      
      # Clean up transcript_offsets - keep only recent files and limit size
      # Sort by pre-collected epoch (descending) to keep most recent
      cleaned_offsets = new_state.transcript_offsets
      |> Enum.filter(fn {filename, _offset} -> MapSet.member?(active_files, filename) end)
      |> Enum.sort_by(fn {filename, _offset} -> 
        Map.get(file_stats, filename, 0)
      end, :desc)
      |> Enum.take(@max_transcript_offsets)
      |> Map.new()
      
      # Log cleanup stats and telemetry
      old_count = map_size(new_state.transcript_offsets)
      new_count = map_size(cleaned_offsets)
      if old_count > new_count do
        require Logger
        Logger.info("SessionBridge: Cleaned up transcript offsets: #{old_count} -> #{new_count}")
      end
      
      # Log periodic telemetry (every cleanup cycle)
      require Logger
      Logger.info("SessionBridge telemetry: transcript_offsets=#{new_count}/#{@max_transcript_offsets}, progress_events=#{length(new_state.progress)}/#{@max_progress_events}, sessions=#{length(new_state.sessions)}")
      
      %{new_state | transcript_offsets: cleaned_offsets, last_cleanup: System.system_time(:millisecond)}
    else
      # Directory scan failed or no files
      new_state
    end
  end

  # Tail the JSONL progress file for new lines
  defp poll_progress(state) do
    case File.stat(Paths.progress_file()) do
      {:ok, %{size: size}} when size > state.progress_offset ->
        case File.open(Paths.progress_file(), [:read]) do
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
    # Use adaptive polling interval for transcripts to reduce overhead
    min_interval = max(state.current_poll_interval, @base_poll_interval)
    if now - state.last_transcript_poll < min_interval do
      state
    else
      do_poll_transcripts(%{state | last_transcript_poll: now})
    end
  end

  # Get cached directory listing if still valid, otherwise refresh
  defp get_cached_directory_files(state, dir) do
    now = System.system_time(:millisecond)
    cache = state.directory_scan_cache
    
    if cache.files && (now - cache.timestamp) < @directory_scan_cache_ttl do
      # Use cached files
      {cache.files, state}
    else
      # Refresh directory listing
      case File.ls(dir) do
        {:ok, files} ->
          new_cache = %{files: files, timestamp: now}
          new_state = %{state | directory_scan_cache: new_cache}
          {files, new_state}
        {:error, _} ->
          {[], state}
      end
    end
  end

  # Optimized: Single-pass directory scan with batched stat calls + directory caching
  defp do_poll_transcripts(state) do
    dir = transcripts_dir()
    
    {files, new_state} = get_cached_directory_files(state, dir)
    
    if files != [] do
      cutoff = System.system_time(:second) - 600  # Last 10 minutes
      
      # Single pass: filter to jsonl files and batch stat
      jsonl_files = files
      |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
      |> Enum.reject(&(&1 == "sessions.json"))
        
      # Batch stat all candidate files once
      recent_files = jsonl_files
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
      
      # Extract new tool calls from each file, using cached sessions for labels
      {new_events, new_offsets} = 
        Enum.reduce(recent_files, {[], new_state.transcript_offsets}, fn {path, file, _size}, {events_acc, offsets_acc} ->
          offset = Map.get(offsets_acc, file, 0)
          {new_events, new_offset} = extract_tool_calls_from_transcript(path, file, offset, new_state.sessions_cache.parsed)
          {events_acc ++ new_events, Map.put(offsets_acc, file, new_offset)}
        end)
      
      if new_events != [] do
        # Merge and deduplicate by timestamp
        updated_progress = (new_state.progress ++ new_events)
        |> Enum.uniq_by(& &1.ts)
        |> Enum.sort_by(& &1.ts)
        |> Enum.take(-@max_progress_events)
        
        broadcast_progress(new_events)
        %{new_state | progress: updated_progress, transcript_offsets: new_offsets}
      else
        %{new_state | transcript_offsets: new_offsets}
      end
    else
      # No files found or directory scan failed
      new_state
    end
  end

  # Optimized: Accept pre-parsed sessions map to avoid repeated file reads
  defp extract_tool_calls_from_transcript(path, filename, offset, sessions_map) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > offset ->
        case File.open(path, [:read]) do
          {:ok, file} ->
            :file.position(file, offset)
            content = IO.read(file, :eof)
            File.close(file)
            
            # Extract session label using cached sessions map (no file read!)
            # Optimize: avoid string allocation by using binary pattern matching
            session_id = case filename do
              <<session::binary-size(byte_size(filename) - 6), ".jsonl">> -> session
              _ -> filename  # fallback for non-.jsonl files
            end
            agent_label = get_session_label_from_cache(session_id, sessions_map)
            
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

  # Optimized: Use pre-parsed sessions map instead of re-reading file
  defp get_session_label_from_cache(session_id, nil), do: String.slice(session_id, 0, 8)
  defp get_session_label_from_cache(session_id, sessions_map) when is_map(sessions_map) do
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
  # Optimized: Uses pre-cached sessions data and caches transcript details
  defp poll_sessions(state) do
    case File.stat(sessions_file()) do
      {:ok, %{mtime: mtime}} when mtime != state.last_session_mtime ->
        # Use cached parsed sessions (already refreshed at start of poll cycle)
        sessions_map = state.sessions_cache.parsed
        
        if sessions_map && is_map(sessions_map) do
          # OpenClaw format: %{"session:key" => %{...session data...}}
          {normalized, new_details_cache} = 
            sessions_map
            |> Enum.map(fn {key, data} -> normalize_session(key, data, state.transcript_details_cache) end)
            |> Enum.filter(fn {session, _cache_entry} -> filter_relevant_session(session) end)
            |> Enum.map(fn {session, cache_entry} -> {session, cache_entry} end)
            |> Enum.sort_by(fn {session, _} -> session.updated_at end, :desc)
            |> Enum.take(20)
            |> Enum.reduce({[], state.transcript_details_cache}, fn {session, cache_entry}, {sessions_acc, cache_acc} ->
              new_cache = if cache_entry, do: Map.put(cache_acc, session.id, cache_entry), else: cache_acc
              {[session | sessions_acc], new_cache}
            end)
          
          normalized = Enum.reverse(normalized)
          broadcast_sessions(normalized)
          %{state | sessions: normalized, last_session_mtime: mtime, transcript_details_cache: new_details_cache}
        else
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

  # Optimized: Returns {session, cache_entry} tuple for caching transcript details
  defp normalize_session(key, s, transcript_cache) do
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
    
    # Extract details from transcript with caching
    {details, cache_entry} = extract_transcript_details_cached(session_id, status, transcript_cache)
    
    {task_summary, result_snippet, runtime, tokens_in, tokens_out, cost, time_info, current_action, recent_actions} = details

    session = %{
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
    
    {session, cache_entry}
  end

  # Optimized: Cache transcript details per session, only re-parse when file changes
  defp extract_transcript_details_cached(session_id, status, transcript_cache) do
    transcript_path = Path.join(transcripts_dir(), "#{session_id}.jsonl")
    
    case File.stat(transcript_path) do
      {:ok, %{mtime: mtime, size: size}} ->
        cached = Map.get(transcript_cache, session_id)
        
        # Check if cache is still valid (same mtime and size)
        # For running sessions, always re-parse to get latest progress
        if cached && cached.mtime == mtime && cached.size == size && status == "completed" do
          # Cache hit! Return cached details
          {cached.details, cached}
        else
          # Cache miss or running session - parse the file
          details = do_extract_transcript_details(transcript_path, status)
          cache_entry = %{mtime: mtime, size: size, details: details}
          {details, cache_entry}
        end
        
      {:error, _} ->
        # File doesn't exist
        {{nil, nil, nil, 0, 0, 0, nil, nil, []}, nil}
    end
  end

  # The actual transcript parsing logic (extracted from original extract_transcript_details)
  defp do_extract_transcript_details(transcript_path, status) do
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
