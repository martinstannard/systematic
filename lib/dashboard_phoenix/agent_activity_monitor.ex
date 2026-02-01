defmodule DashboardPhoenix.AgentActivityMonitor do
  @moduledoc """
  Monitors coding agent activity by parsing session transcripts.
  Watches OpenClaw sessions, Claude Code, OpenCode, and Codex.
  """
  use GenServer

  require Logger

  alias DashboardPhoenix.{CLITools, Paths, ProcessParser, StatePersistence, Status}

  # Type definitions
  @typedoc "Agent type classification"
  @type agent_type :: :openclaw | :claude_code | :opencode | :codex | :unknown

  @typedoc "Action performed by an agent"
  @type action :: %{
          action: String.t(),
          target: String.t() | nil,
          timestamp: DateTime.t() | nil
        }

  @typedoc "Agent activity information"
  @type agent_activity :: %{
          id: String.t(),
          session_id: String.t(),
          type: agent_type(),
          model: String.t(),
          cwd: String.t() | nil,
          status: String.t(),
          last_action: action() | nil,
          recent_actions: list(action()),
          files_worked: list(String.t()),
          last_activity: DateTime.t(),
          tool_call_count: non_neg_integer()
        }

  @typedoc "Internal GenServer state"
  @type state :: %{
          agents: %{optional(String.t()) => agent_activity()},
          session_offsets: %{optional(String.t()) => non_neg_integer()},
          last_poll: non_neg_integer() | nil,
          polling: boolean(),
          last_cache_cleanup: non_neg_integer()
        }

  @poll_interval 5_000  # 5 seconds - less aggressive updates
  @max_recent_actions 10
  @cli_timeout_ms 10_000
  @persistence_file "agent_activity_state.json"
  @transcript_cache_table :transcript_cache
  @cache_cleanup_interval 300_000  # 5 minutes
  @max_cache_entries 1000
  @file_retry_attempts 3
  @file_retry_delay 100
  @gc_interval 300_000  # Trigger GC every 5 minutes (Ticket #79)

  @spec openclaw_sessions_dir() :: String.t()
  defp openclaw_sessions_dir, do: Paths.openclaw_sessions_dir()

  @doc "Starts the AgentActivityMonitor GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc """
  Get current activity for all monitored agents.
  Returns a list of agent activity maps.
  """
  @spec get_activity() :: list(agent_activity())
  def get_activity do
    GenServer.call(__MODULE__, :get_activity, 5_000)
  end

  @doc "Subscribe to agent activity updates via PubSub."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_activity")
  end

  # GenServer callbacks

  @impl true
  @spec init(term()) :: {:ok, state()}
  def init(_) do
    # Create ETS table for transcript caching
    # Key: path, Value: {mtime, agent_data}
    # Delete existing table to ensure clean state (handles restarts and tests)
    case :ets.whereis(@transcript_cache_table) do
      :undefined -> :ok
      _ref -> :ets.delete(@transcript_cache_table)
    end
    :ets.new(@transcript_cache_table, [:named_table, :set, :public])
    
    schedule_poll()
    schedule_cache_cleanup()
    schedule_gc()
    
    default_agent = %{
      id: "",
      session_id: "",
      type: :openclaw,
      model: "",
      cwd: "",
      status: "",
      last_action: %{action: "", target: "", timestamp: nil},
      recent_actions: [%{action: "", target: "", timestamp: nil}],
      files_worked: [],
      last_activity: nil,
      tool_call_count: 0
    }

    default_state = %{
      agents: %{__template__: default_agent},
      session_offsets: %{},
      last_poll: nil,
      polling: false,  # Mutex to prevent concurrent polls
      last_cache_cleanup: System.system_time(:millisecond)
    }
    
    persisted_state = StatePersistence.load(@persistence_file, default_state)
    state = fix_loaded_state(persisted_state)
    
    {:ok, state}
  end

  @spec fix_loaded_state(map()) :: state()
  defp fix_loaded_state(state) do
    # Remove template from agents map if it leaked through (it shouldn't if load is correct)
    agents = Map.delete(state.agents, :__template__)

    # Convert string timestamps back to DateTime in the agents map
    fixed_agents = for {id, agent} <- agents, into: %{} do
      fixed_agent = agent
      |> Map.update(:last_activity, DateTime.utc_now(), &parse_timestamp/1)
      |> Map.update(:recent_actions, [], fn actions ->
        Enum.map(actions, fn action ->
          Map.update(action, :timestamp, DateTime.utc_now(), &parse_timestamp/1)
        end)
      end)
      
      {id, fixed_agent}
    end
    
    # Ensure required fields exist for race condition fixes
    state = state
    |> Map.put_new(:session_offsets, %{})
    |> Map.put_new(:polling, false)
    |> Map.put_new(:last_cache_cleanup, System.system_time(:millisecond))
    
    %{state | agents: fixed_agents}
  end

  @impl true
  @spec handle_call(:get_activity, GenServer.from(), state()) :: {:reply, list(agent_activity()), state()}
  def handle_call(:get_activity, _from, state) do
    activities = state.agents
    |> Map.values()
    |> Enum.sort_by(& &1.last_activity, {:desc, DateTime})
    
    {:reply, activities, state}
  end

  @impl true
  @spec handle_info(:poll | {:poll_complete, state()} | {:poll_error, term()} | :cleanup_cache, state()) :: {:noreply, state()}
  def handle_info(:poll, state) do
    # Prevent concurrent polls - critical for race condition fix
    if state.polling do
      Logger.debug("AgentActivityMonitor: Poll already in progress, skipping")
      schedule_poll()
      {:noreply, state}
    else
      # Mark as polling and start async poll
      state = %{state | polling: true}
      parent = self()
      
      Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
        try do
          new_state = poll_agent_activity(state)
          send(parent, {:poll_complete, new_state})
        rescue
          e ->
            Logger.error("AgentActivityMonitor: Poll failed: #{inspect(e)}")
            send(parent, {:poll_error, e})
        end
      end)
      
      {:noreply, state}
    end
  end

  @impl true  
  def handle_info({:poll_complete, updated_state}, _state) do
    # Reset polling flag and update state atomically
    final_state = %{updated_state | polling: false}
    schedule_poll()
    {:noreply, final_state}
  end
  
  @impl true
  def handle_info({:poll_error, _error}, state) do
    # Reset polling flag on error
    state = %{state | polling: false}
    schedule_poll()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    cleanup_transcript_cache()
    schedule_cache_cleanup()
    {:noreply, %{state | last_cache_cleanup: System.system_time(:millisecond)}}
  end

  @impl true
  def handle_info(:gc_trigger, state) do
    alias DashboardPhoenix.MemoryUtils
    MemoryUtils.trigger_gc(__MODULE__)
    schedule_gc()
    {:noreply, state}
  end

  @spec schedule_poll() :: reference()
  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  @spec schedule_cache_cleanup() :: reference()
  defp schedule_cache_cleanup do
    Process.send_after(self(), :cleanup_cache, @cache_cleanup_interval)
  end

  @spec schedule_gc() :: reference()
  defp schedule_gc do
    Process.send_after(self(), :gc_trigger, @gc_interval)
  end

  @spec cleanup_transcript_cache() :: :ok
  defp cleanup_transcript_cache do
    try do
      # Get all cache entries
      all_entries = :ets.tab2list(@transcript_cache_table)
      entry_count = length(all_entries)
      
      if entry_count > @max_cache_entries do
        Logger.info("AgentActivityMonitor: Cleaning cache, #{entry_count} entries")
        
        # Sort by mtime (oldest first) and remove oldest entries
        sorted_entries = Enum.sort_by(all_entries, fn {_path, mtime, _agent} -> mtime end)
        entries_to_remove = Enum.take(sorted_entries, entry_count - @max_cache_entries)
        
        for {path, _mtime, _agent} <- entries_to_remove do
          :ets.delete(@transcript_cache_table, path)
        end
        
        Logger.info("AgentActivityMonitor: Removed #{length(entries_to_remove)} cache entries")
      end
    rescue
      e ->
        Logger.warning("AgentActivityMonitor: Cache cleanup failed: #{inspect(e)}")
    end
  end

  @spec poll_agent_activity(state()) :: state()
  defp poll_agent_activity(state) do
    # Combine multiple sources with proper error handling
    {openclaw_agents, new_offsets} = parse_openclaw_sessions_with_offsets(state)
    process_agents = find_coding_agent_processes()
    
    # Merge agent info - prefer session data but add process info
    merged = merge_agent_info(openclaw_agents, process_agents, state.agents)
    
    # Update state with new offsets
    updated_state = %{state | 
      agents: merged, 
      session_offsets: new_offsets,
      last_poll: System.system_time(:millisecond)
    }
    
    # Broadcast if there are changes (atomic comparison)
    if merged != state.agents do
      # Save state asynchronously to avoid blocking
      Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
        StatePersistence.save(@persistence_file, updated_state)
      end)
      
      broadcast_activity(merged)
    end
    
    updated_state
  end

  @spec parse_openclaw_sessions_with_offsets(state()) :: {%{optional(String.t()) => agent_activity()}, map()}
  defp parse_openclaw_sessions_with_offsets(state) do
    {agents, offsets} = parse_openclaw_sessions(state)
    {agents, offsets}
  end

  @spec parse_openclaw_sessions(state()) :: {%{optional(String.t()) => agent_activity()}, map()}
  defp parse_openclaw_sessions(state) do
    sessions_dir = openclaw_sessions_dir()
    
    case File.ls(sessions_dir) do
      {:ok, files} ->
        # Get the most recent sessions (modified in last 30 minutes)
        cutoff = System.system_time(:second) - 30 * 60
        
        results = files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn file ->
          path = Path.join(sessions_dir, file)
          case File.stat(path) do
            {:ok, %{mtime: mtime}} ->
              epoch = mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
              if epoch > cutoff, do: {path, file, mtime}, else: nil
            {:error, reason} ->
              Logger.debug("AgentActivityMonitor: Failed to stat file #{path}: #{inspect(reason)}")
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_, _, mtime} -> mtime end, :desc)
        |> Enum.take(5)  # Monitor top 5 most recent sessions
        |> Enum.map(fn {path, file, mtime} -> 
          {parse_session_file(path, file, mtime, state.session_offsets), path}
        end)
        |> Enum.reject(fn {agent, _path} -> is_nil(agent) end)

        # Separate agents and collect new offsets
        agents = results
        |> Enum.map(fn {agent, _path} -> {agent.id, agent} end)
        |> Map.new()

        new_offsets = results
        |> Enum.reduce(state.session_offsets, fn {agent, path}, offsets ->
          if agent && Map.has_key?(agent, :file_offset) do
            Map.put(offsets, path, agent.file_offset)
          else
            offsets
          end
        end)

        {agents, new_offsets}
        
      {:error, :enoent} ->
        Logger.debug("AgentActivityMonitor: Sessions directory #{sessions_dir} does not exist")
        {%{}, state.session_offsets}
      {:error, reason} ->
        Logger.warning("AgentActivityMonitor: Failed to read sessions directory #{sessions_dir}: #{inspect(reason)}")
        {%{}, state.session_offsets}
    end
  rescue
    e ->
      Logger.error("AgentActivityMonitor: Exception in parse_openclaw_sessions: #{inspect(e)}")
      {%{}, state.session_offsets}
  end

  @spec parse_session_file(String.t(), String.t(), term(), map()) :: agent_activity() | nil
  defp parse_session_file(path, filename, mtime, offsets) do
    # Atomic cache lookup with proper error handling
    case safe_cache_lookup(path, mtime) do
      {:hit, cached_agent} ->
        cached_agent
        
      {:miss, :not_found} ->
        # Cache miss - parse and cache
        parse_and_cache_session(path, filename, mtime, offsets)
        
      {:miss, :mtime_changed} ->
        # File changed - reparse with incremental read if possible
        parse_and_cache_session(path, filename, mtime, offsets)
    end
  end

  @spec safe_cache_lookup(String.t(), term()) :: {:hit, agent_activity()} | {:miss, :not_found | :mtime_changed}
  defp safe_cache_lookup(path, expected_mtime) do
    try do
      case :ets.lookup(@transcript_cache_table, path) do
        [{^path, ^expected_mtime, cached_agent}] ->
          {:hit, cached_agent}
        [{^path, _different_mtime, _agent}] ->
          {:miss, :mtime_changed} 
        [] ->
          {:miss, :not_found}
      end
    rescue
      e ->
        Logger.warning("AgentActivityMonitor: Cache lookup failed for #{path}: #{inspect(e)}")
        {:miss, :not_found}
    end
  end

  @spec parse_and_cache_session(String.t(), String.t(), term(), map()) :: agent_activity() | nil
  defp parse_and_cache_session(path, filename, mtime, offsets) do
    case read_file_with_retry_and_offset(path, Map.get(offsets, path, 0)) do
      {:ok, content, new_offset} ->
        lines = String.split(content, "\n", trim: true)
        events = lines
        |> Enum.map(&parse_jsonl_line/1)
        |> Enum.reject(&is_nil/1)
        
        agent = extract_agent_activity(events, filename)
        
        # Update agent with offset info for incremental reads
        agent = if agent, do: Map.put(agent, :file_offset, new_offset), else: nil
        
        # Atomically cache the result with mtime
        if agent do
          safe_cache_insert(path, mtime, agent)
        end
        
        agent
        
      {:error, :enoent} ->
        Logger.debug("AgentActivityMonitor: Session file #{path} no longer exists")
        nil
      {:error, :eacces} ->
        Logger.warning("AgentActivityMonitor: Permission denied reading session file #{path}")
        nil
      {:error, reason} ->
        Logger.warning("AgentActivityMonitor: Failed to read session file #{path}: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.error("AgentActivityMonitor: Exception parsing session file #{path}: #{inspect(e)}")
      nil
  end

  @spec read_file_with_retry_and_offset(String.t(), non_neg_integer()) :: {:ok, String.t(), non_neg_integer()} | {:error, term()}
  defp read_file_with_retry_and_offset(path, offset) do
    read_file_with_retry(path, offset, @file_retry_attempts)
  end

  @spec read_file_with_retry(String.t(), non_neg_integer(), non_neg_integer()) :: {:ok, String.t(), non_neg_integer()} | {:error, term()}
  defp read_file_with_retry(_path, _offset, 0) do
    {:error, :max_retries_exceeded}
  end

  defp read_file_with_retry(path, offset, attempts_left) do
    try do
      case File.open(path, [:read, :binary]) do
        {:ok, file} ->
          try do
            # Seek to offset for incremental read
            if offset > 0 do
              case :file.position(file, offset) do
                {:ok, _pos} -> :ok
                {:error, _reason} -> 
                  Logger.debug("AgentActivityMonitor: Failed to seek to offset #{offset} in #{path}, reading from start")
                  :file.position(file, 0)
              end
            end
            
            # Read remaining content
            case IO.read(file, :all) do
              {:error, reason} -> 
                {:error, reason}
              content when is_binary(content) ->
                new_offset = offset + byte_size(content)
                {:ok, content, new_offset}
            end
          after
            File.close(file)
          end
          
        {:error, :enoent} -> 
          {:error, :enoent}
        {:error, :eacces} -> 
          {:error, :eacces}
        {:error, reason} -> 
          # Retry on other errors (file locked, etc.)
          if attempts_left > 1 do
            Process.sleep(@file_retry_delay)
            read_file_with_retry(path, offset, attempts_left - 1)
          else
            {:error, reason}
          end
      end
    rescue
      e ->
        if attempts_left > 1 do
          Logger.debug("AgentActivityMonitor: Retry #{@file_retry_attempts - attempts_left + 1} for #{path}: #{inspect(e)}")
          Process.sleep(@file_retry_delay)
          read_file_with_retry(path, offset, attempts_left - 1)
        else
          {:error, {:exception, e}}
        end
    end
  end

  @spec safe_cache_insert(String.t(), term(), agent_activity()) :: true | :ok
  defp safe_cache_insert(path, mtime, agent) do
    try do
      :ets.insert(@transcript_cache_table, {path, mtime, agent})
    rescue
      e ->
        Logger.warning("AgentActivityMonitor: Failed to cache result for #{path}: #{inspect(e)}")
    end
  end

  @spec parse_jsonl_line(String.t()) :: map() | nil
  defp parse_jsonl_line(line) do
    case Jason.decode(line) do
      {:ok, data} -> data
      {:error, %Jason.DecodeError{} = e} ->
        Logger.debug("AgentActivityMonitor: Failed to decode JSON line: #{Exception.message(e)}")
        nil
      {:error, reason} ->
        Logger.debug("AgentActivityMonitor: JSON decode error: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.debug("AgentActivityMonitor: Exception decoding JSON line: #{inspect(e)}")
      nil
  end

  @spec extract_agent_activity(list(map()), String.t()) :: agent_activity()
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

  @spec extract_files_from_tool_call(map()) :: list(String.t())
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

  @spec extract_files_from_command(term()) :: list(String.t())
  defp extract_files_from_command(command) when is_binary(command) do
    # Extract file paths from common commands
    Regex.scan(~r{(?:^|\s)([~/.][\w./\-]+\.\w+)}, command)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.take(5)
  end
  defp extract_files_from_command(_), do: []

  @spec determine_status(map() | nil, list(map())) :: String.t()
  defp determine_status(last_message, tool_calls) do
    cond do
      is_nil(last_message) -> Status.idle()
      last_message["message"]["role"] == "assistant" and 
        has_pending_tool_calls?(last_message) -> "executing"
      last_message["message"]["role"] == "toolResult" -> "thinking"
      last_message["message"]["role"] == "user" -> "processing"
      length(tool_calls) == 0 -> Status.idle()
      true -> Status.active()
    end
  end

  @spec has_pending_tool_calls?(map()) :: boolean()
  defp has_pending_tool_calls?(message) do
    content = message["message"]["content"] || []
    Enum.any?(content, & is_map(&1) and &1["type"] == "toolCall")
  end

  @spec format_action(map() | nil) :: action() | nil
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

  @spec parse_timestamp(term()) :: DateTime.t()
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

  @spec find_coding_agent_processes() :: %{optional(String.t()) => agent_activity()}
  defp find_coding_agent_processes do
    ProcessParser.list_processes(
      sort: "-start_time",
      filter: &coding_agent_process?/1,
      timeout: @cli_timeout_ms
    )
    |> Enum.map(&transform_process_to_agent/1)
    |> Map.new(fn a -> {a.id, a} end)
  end

  @spec coding_agent_process?(String.t()) :: boolean()
  defp coding_agent_process?(line) do
    ProcessParser.contains_patterns?(line, ~w(claude opencode codex)) and
    not String.contains?(String.downcase(line), "grep") and
    not String.contains?(String.downcase(line), "ps aux")
  end

  @spec transform_process_to_agent(map()) :: agent_activity()
  defp transform_process_to_agent(%{pid: pid, cpu: cpu, mem: mem, start: start, command: command}) do
    type = detect_agent_type(command)
    cwd = get_process_cwd(pid)
    
    %{
      id: "process-#{pid}",
      session_id: pid,
      type: type,
      model: detect_model_from_command(command),
      cwd: cwd,
      status: if(cpu > 5.0, do: Status.busy(), else: Status.idle()),
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

  @spec detect_agent_type(String.t()) :: agent_type()
  defp detect_agent_type(command) do
    cmd_lower = String.downcase(command)
    cond do
      String.contains?(cmd_lower, "claude") -> :claude_code
      String.contains?(cmd_lower, "opencode") -> :opencode
      String.contains?(cmd_lower, "codex") -> :codex
      true -> :unknown
    end
  end

  @spec detect_model_from_command(String.t()) :: String.t()
  defp detect_model_from_command(command) do
    cond do
      String.contains?(command, "opus") -> "claude-opus"
      String.contains?(command, "sonnet") -> "claude-sonnet"
      String.contains?(command, "gemini") -> "gemini"
      true -> "unknown"
    end
  end

  @spec get_process_cwd(String.t() | integer()) :: String.t() | nil
  defp get_process_cwd(pid) do
    proc_path = "/proc/#{pid}/cwd"
    case File.read_link(proc_path) do
      {:ok, cwd} -> cwd
      {:error, :enoent} ->
        # Process no longer exists
        Logger.debug("AgentActivityMonitor: Process #{pid} no longer exists")
        nil
      {:error, :eacces} ->
        # Permission denied to read process info
        Logger.debug("AgentActivityMonitor: Permission denied reading process #{pid} info")
        nil
      {:error, reason} ->
        Logger.debug("AgentActivityMonitor: Failed to read process #{pid} working directory: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.debug("AgentActivityMonitor: Exception reading process #{pid} cwd: #{inspect(e)}")
      nil
  end

  @spec get_recently_modified_files(String.t() | nil) :: list(String.t())
  defp get_recently_modified_files(nil), do: []
  defp get_recently_modified_files(cwd) do
    case CLITools.run_if_available("find", [cwd, "-maxdepth", "3", "-type", "f", "-mmin", "-5", 
                             "-name", "*.ex", "-o", "-name", "*.exs", 
                             "-o", "-name", "*.ts", "-o", "-name", "*.js",
                             "-o", "-name", "*.py", "-o", "-name", "*.rb"], 
                    timeout: @cli_timeout_ms, friendly_name: "find") do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.take(10)
        
      {:error, {:tool_not_available, _}} ->
        []
        
      {:error, _} ->
        []
    end
  rescue
    _ -> []
  end

  @spec merge_agent_info(map(), map(), map()) :: %{optional(String.t()) => agent_activity()}
  defp merge_agent_info(openclaw_agents, process_agents, _existing) do
    # Prefer OpenClaw session data, supplement with process info
    Map.merge(process_agents, openclaw_agents)
  end

  @spec broadcast_activity(map()) :: :ok | {:error, term()}
  defp broadcast_activity(agents) do
    activities = agents |> Map.values() |> Enum.sort_by(& &1.last_activity, {:desc, DateTime})
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "agent_activity", {:agent_activity, activities})
  end

  @spec truncate(term(), pos_integer()) :: String.t()
  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end
  defp truncate(_, _), do: ""

end
