defmodule DashboardPhoenix.AgentActivityMonitor.Server do
  @moduledoc """
  Portable GenServer for monitoring coding agent activity.
  
  This is the configurable core of AgentActivityMonitor. It can be used:
  - Standalone with minimal config for testing or simple use cases
  - With full DashboardPhoenix integration using Config.dashboard_defaults()
  - Embedded in other applications with custom persistence/broadcasting
  
  ## Usage
  
  ### Minimal (testing/standalone)
  
      config = AgentActivityMonitor.Config.minimal("/path/to/sessions")
      {:ok, pid} = Server.start_link(config: config)
      activities = Server.get_activity(pid)
  
  ### With DashboardPhoenix
  
      config = AgentActivityMonitor.Config.dashboard_defaults()
      {:ok, pid} = Server.start_link(config: config)
      # Uses Phoenix.PubSub for broadcasting, TaskSupervisor, etc.
  
  ### Custom configuration
  
      config = %Config{
        sessions_dir: "/custom/sessions",
        pubsub: {MyApp.PubSub, "agents"},
        poll_interval_ms: 10_000,
        save_state: &MyApp.Persistence.save/2,
        load_state: &MyApp.Persistence.load/2
      }
      {:ok, pid} = Server.start_link(config: config)
  """
  use GenServer

  require Logger

  alias DashboardPhoenix.AgentActivityMonitor.{Config, SessionParser}

  @typedoc "Internal GenServer state"
  @type state :: %{
          config: Config.t(),
          agents: %{optional(String.t()) => SessionParser.agent_activity()},
          session_offsets: %{optional(String.t()) => non_neg_integer()},
          last_poll: non_neg_integer() | nil,
          polling: boolean(),
          last_cache_cleanup: non_neg_integer()
        }

  @transcript_cache_table :transcript_cache

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the AgentActivityMonitor server.
  
  ## Options
  - `:config` - A Config struct (required or uses dashboard defaults)
  - `:name` - GenServer name (overrides config.name)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.get_lazy(opts, :config, &Config.dashboard_defaults/0)
    name = Keyword.get(opts, :name, config.name)
    
    case Config.validate(config) do
      {:ok, valid_config} ->
        gen_opts = if name, do: [name: name], else: []
        GenServer.start_link(__MODULE__, valid_config, gen_opts ++ [hibernate_after: 15_000])
        
      {:error, reason} ->
        {:error, {:invalid_config, reason}}
    end
  end

  @doc """
  Get current activity for all monitored agents.
  
  Can be called with a pid/name or defaults to the registered name.
  """
  @spec get_activity(GenServer.server()) :: list(SessionParser.agent_activity())
  def get_activity(server \\ DashboardPhoenix.AgentActivityMonitor) do
    GenServer.call(server, :get_activity, 5_000)
  end

  @doc """
  Subscribe to agent activity updates via PubSub.
  
  Only works if the server was configured with a pubsub option.
  """
  @spec subscribe(GenServer.server()) :: :ok | {:error, :no_pubsub_configured}
  def subscribe(server \\ DashboardPhoenix.AgentActivityMonitor) do
    GenServer.call(server, :get_pubsub_config, 1_000)
    |> case do
      nil -> 
        {:error, :no_pubsub_configured}
      {pubsub_module, topic} ->
        Phoenix.PubSub.subscribe(pubsub_module, topic)
    end
  end

  @doc """
  Returns the current config.
  """
  @spec get_config(GenServer.server()) :: Config.t()
  def get_config(server \\ DashboardPhoenix.AgentActivityMonitor) do
    GenServer.call(server, :get_config, 1_000)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    # Create or reset ETS table for transcript caching
    case :ets.whereis(@transcript_cache_table) do
      :undefined -> :ok
      _ref -> :ets.delete(@transcript_cache_table)
    end
    :ets.new(@transcript_cache_table, [:named_table, :set, :public])
    
    schedule_poll(config.poll_interval_ms)
    schedule_cache_cleanup(config.cache_cleanup_interval_ms)
    schedule_gc(config.gc_interval_ms)
    
    default_state = %{
      config: config,
      agents: %{},
      session_offsets: %{},
      last_poll: nil,
      polling: false,
      last_cache_cleanup: System.system_time(:millisecond)
    }
    
    # Load persisted state if a load function is configured
    state = if config.load_state do
      try do
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
        
        default_for_load = %{
          agents: %{__template__: default_agent},
          session_offsets: %{},
          last_poll: nil,
          polling: false,
          last_cache_cleanup: System.system_time(:millisecond)
        }
        
        loaded = config.load_state.(config.persistence_file, default_for_load)
        fix_loaded_state(loaded, config)
      rescue
        e ->
          Logger.warning("AgentActivityMonitor: Failed to load persisted state: #{inspect(e)}")
          default_state
      end
    else
      default_state
    end
    
    {:ok, state}
  end

  @impl true
  def handle_call(:get_activity, _from, state) do
    activities = state.agents
    |> Map.values()
    |> Enum.sort_by(& &1.last_activity, {:desc, DateTime})
    
    {:reply, activities, state}
  end

  @impl true
  def handle_call(:get_pubsub_config, _from, state) do
    {:reply, state.config.pubsub, state}
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  @impl true
  def handle_info(:poll, %{polling: true} = state) do
    Logger.debug("AgentActivityMonitor: Poll already in progress, skipping")
    schedule_poll(state.config.poll_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    # Mark as polling and start async poll
    state = %{state | polling: true}
    parent = self()
    config = state.config
    
    poll_fn = fn ->
      try do
        new_state = poll_agent_activity(state)
        send(parent, {:poll_complete, new_state})
      rescue
        e ->
          Logger.error("AgentActivityMonitor: Poll failed: #{inspect(e)}")
          send(parent, {:poll_error, e})
      end
    end
    
    # Use TaskSupervisor if configured, otherwise spawn directly
    if config.task_supervisor do
      Task.Supervisor.start_child(config.task_supervisor, poll_fn)
    else
      spawn(poll_fn)
    end
    
    {:noreply, state}
  end

  @impl true  
  def handle_info({:poll_complete, updated_state}, _state) do
    final_state = %{updated_state | polling: false}
    schedule_poll(final_state.config.poll_interval_ms)
    {:noreply, final_state}
  end
  
  @impl true
  def handle_info({:poll_error, _error}, state) do
    state = %{state | polling: false}
    schedule_poll(state.config.poll_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup_cache, state) do
    cleanup_transcript_cache(state.config.max_cache_entries)
    schedule_cache_cleanup(state.config.cache_cleanup_interval_ms)
    {:noreply, %{state | last_cache_cleanup: System.system_time(:millisecond)}}
  end

  @impl true
  def handle_info(:gc_trigger, state) do
    # Trigger garbage collection - use MemoryUtils if available
    if Code.ensure_loaded?(DashboardPhoenix.MemoryUtils) do
      DashboardPhoenix.MemoryUtils.trigger_gc(__MODULE__)
    else
      :erlang.garbage_collect()
    end
    schedule_gc(state.config.gc_interval_ms)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp schedule_cache_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup_cache, interval_ms)
  end

  defp schedule_gc(interval_ms) do
    Process.send_after(self(), :gc_trigger, interval_ms)
  end

  defp cleanup_transcript_cache(max_entries) do
    try do
      all_entries = :ets.tab2list(@transcript_cache_table)
      entry_count = length(all_entries)
      
      if entry_count > max_entries do
        Logger.info("AgentActivityMonitor: Cleaning cache, #{entry_count} entries")
        
        sorted_entries = Enum.sort_by(all_entries, fn {_path, mtime, _agent} -> mtime end)
        entries_to_remove = Enum.take(sorted_entries, entry_count - max_entries)
        
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

  defp fix_loaded_state(loaded, config) do
    # Remove template from agents map
    agents = Map.delete(loaded.agents || %{}, :__template__)

    # Convert string timestamps back to DateTime
    fixed_agents = for {id, agent} <- agents, into: %{} do
      fixed_agent = agent
      |> Map.update(:last_activity, DateTime.utc_now(), &SessionParser.parse_timestamp/1)
      |> Map.update(:recent_actions, [], fn actions ->
        Enum.map(actions, fn action ->
          Map.update(action, :timestamp, DateTime.utc_now(), &SessionParser.parse_timestamp/1)
        end)
      end)
      
      {id, fixed_agent}
    end
    
    %{
      config: config,
      agents: fixed_agents,
      session_offsets: loaded.session_offsets || %{},
      last_poll: loaded.last_poll,
      polling: false,
      last_cache_cleanup: System.system_time(:millisecond)
    }
  end

  defp poll_agent_activity(state) do
    config = state.config
    
    # Parse OpenClaw sessions
    {openclaw_agents, new_offsets} = parse_openclaw_sessions(state)
    
    # Optionally get process-based agents
    process_agents = if config.monitor_processes? do
      find_coding_agent_processes(config)
    else
      %{}
    end
    
    # Merge agent info - prefer session data
    merged = Map.merge(process_agents, openclaw_agents)
    
    # Update state with new offsets
    updated_state = %{state | 
      agents: merged, 
      session_offsets: new_offsets,
      last_poll: System.system_time(:millisecond)
    }
    
    # Broadcast and persist if there are changes
    if merged != state.agents do
      # Save state asynchronously if configured
      maybe_save_state(config, updated_state)
      
      # Broadcast if configured
      maybe_broadcast(config, merged)
    end
    
    updated_state
  end

  defp maybe_save_state(%{save_state: nil}, _state), do: :ok
  defp maybe_save_state(%{save_state: save_fn, task_supervisor: nil} = config, state) do
    spawn(fn -> 
      save_fn.(config.persistence_file, state) 
    end)
  end
  defp maybe_save_state(%{save_state: save_fn, task_supervisor: supervisor} = config, state) do
    Task.Supervisor.start_child(supervisor, fn ->
      save_fn.(config.persistence_file, state)
    end)
  end

  defp maybe_broadcast(%{pubsub: nil}, _agents), do: :ok
  defp maybe_broadcast(%{pubsub: {pubsub_module, topic}}, agents) do
    activities = agents |> Map.values() |> Enum.sort_by(& &1.last_activity, {:desc, DateTime})
    Phoenix.PubSub.broadcast(pubsub_module, topic, {:agent_activity, activities})
  end

  defp parse_openclaw_sessions(state) do
    config = state.config
    sessions_dir = config.sessions_dir
    
    case File.ls(sessions_dir) do
      {:ok, files} ->
        cutoff = System.system_time(:second) - 30 * 60
        
        results = files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn file ->
          path = Path.join(sessions_dir, file)
          case File.stat(path) do
            {:ok, %{mtime: mtime}} ->
              epoch = mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
              if epoch > cutoff, do: {path, file, mtime}, else: nil
            {:error, _} ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(fn {_, _, mtime} -> mtime end, :desc)
        |> Enum.take(5)
        |> Enum.map(fn {path, file, mtime} -> 
          {parse_session_file(path, file, mtime, state), path}
        end)
        |> Enum.reject(fn {agent, _path} -> is_nil(agent) end)

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

  defp parse_session_file(path, filename, mtime, state) do
    case safe_cache_lookup(path, mtime) do
      {:hit, cached_agent} ->
        cached_agent
        
      {:miss, _reason} ->
        parse_and_cache_session(path, filename, mtime, state)
    end
  end

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

  defp parse_and_cache_session(path, filename, mtime, state) do
    config = state.config
    offset = Map.get(state.session_offsets, path, 0)
    
    case read_file_with_retry(path, offset, config) do
      {:ok, content, new_offset} ->
        activity = SessionParser.parse_content(content, filename, 
          max_actions: config.max_recent_actions)
        
        # Add offset info for incremental reads
        agent = Map.put(activity, :file_offset, new_offset)
        
        # Cache the result
        safe_cache_insert(path, mtime, agent)
        
        agent
        
      {:error, _reason} ->
        nil
    end
  rescue
    e ->
      Logger.error("AgentActivityMonitor: Exception parsing session file #{path}: #{inspect(e)}")
      nil
  end

  defp read_file_with_retry(path, offset, config, attempts_left \\ nil) do
    attempts_left = attempts_left || config.file_retry_attempts
    
    try do
      case File.open(path, [:read, :binary]) do
        {:ok, file} ->
          try do
            if offset > 0 do
              case :file.position(file, offset) do
                {:ok, _pos} -> :ok
                {:error, _reason} -> :file.position(file, 0)
              end
            end
            
            case IO.read(file, :eof) do
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
          if attempts_left > 1 do
            Process.sleep(config.file_retry_delay_ms)
            read_file_with_retry(path, offset, config, attempts_left - 1)
          else
            {:error, reason}
          end
      end
    rescue
      e ->
        if attempts_left > 1 do
          Process.sleep(config.file_retry_delay_ms)
          read_file_with_retry(path, offset, config, attempts_left - 1)
        else
          {:error, {:exception, e}}
        end
    end
  end

  defp safe_cache_insert(path, mtime, agent) do
    try do
      :ets.insert(@transcript_cache_table, {path, mtime, agent})
    rescue
      e ->
        Logger.warning("AgentActivityMonitor: Failed to cache result for #{path}: #{inspect(e)}")
    end
  end

  # Process monitoring (optional)
  
  defp find_coding_agent_processes(config) do
    # Use ProcessParser if available, otherwise skip
    if Code.ensure_loaded?(DashboardPhoenix.ProcessParser) do
      DashboardPhoenix.ProcessParser.list_processes(
        sort: "-start_time",
        filter: &coding_agent_process?/1,
        timeout: config.cli_timeout_ms
      )
      |> Enum.map(&transform_process_to_agent/1)
      |> Map.new(fn a -> {a.id, a} end)
    else
      %{}
    end
  end

  defp coding_agent_process?(line) do
    patterns = ~w(claude opencode codex)
    line_lower = String.downcase(line)
    Enum.any?(patterns, &String.contains?(line_lower, &1)) and
    not String.contains?(line_lower, "grep") and
    not String.contains?(line_lower, "ps aux")
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
      files_worked: [],
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
    proc_path = "/proc/#{pid}/cwd"
    case File.read_link(proc_path) do
      {:ok, cwd} -> cwd
      {:error, _} -> nil
    end
  rescue
    _ -> nil
  end
end
