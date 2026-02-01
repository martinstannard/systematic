defmodule AgentActivityMonitor.Server do
  @moduledoc """
  Portable GenServer for monitoring coding agent activity.
  
  This is the configurable core of AgentActivityMonitor. It can be used:
  - Standalone with minimal config for testing or simple use cases
  - Embedded in other applications with custom persistence/broadcasting
  - With framework-specific wrappers (e.g., Phoenix/LiveView integration)
  
  ## Usage
  
  ### Minimal (testing/standalone)
  
      config = AgentActivityMonitor.Config.minimal("/path/to/sessions")
      {:ok, pid} = Server.start_link(config: config)
      activities = Server.get_activity(pid)
  
  ### Named server
  
      config = AgentActivityMonitor.Config.new("/path/to/sessions", name: MyApp.AgentMonitor)
      {:ok, _pid} = Server.start_link(config: config)
      activities = Server.get_activity(MyApp.AgentMonitor)
  
  ### With PubSub broadcasting
  
      config = AgentActivityMonitor.Config.new("/path/to/sessions",
        pubsub: {MyApp.PubSub, "agent_activity"},
        name: MyApp.AgentMonitor
      )
      {:ok, _pid} = Server.start_link(config: config)
      
      # Subscribe to updates
      Server.subscribe(MyApp.AgentMonitor)
  
  ### Full configuration
  
      config = %AgentActivityMonitor.Config{
        sessions_dir: "/custom/sessions",
        pubsub: {MyApp.PubSub, "agents"},
        poll_interval_ms: 10_000,
        task_supervisor: MyApp.TaskSupervisor,
        save_state: &MyApp.Persistence.save/2,
        load_state: &MyApp.Persistence.load/2,
        gc_trigger: &MyApp.MemoryUtils.trigger_gc/1,
        find_processes: &MyApp.ProcessFinder.find/1,
        name: MyApp.AgentMonitor
      }
      {:ok, _pid} = Server.start_link(config: config)
  
  ## Architecture
  
  The server:
  - Polls session files at configurable intervals
  - Caches parsed transcripts in ETS to minimize re-parsing
  - Optionally broadcasts updates via Phoenix.PubSub
  - Optionally persists state across restarts
  - Optionally monitors system processes for coding agents
  """
  use GenServer

  require Logger

  alias AgentActivityMonitor.{Config, SessionParser}

  @typedoc "Internal GenServer state"
  @type state :: %{
          config: Config.t(),
          agents: %{optional(String.t()) => SessionParser.agent_activity()},
          session_offsets: %{optional(String.t()) => non_neg_integer()},
          last_poll: non_neg_integer() | nil,
          polling: boolean(),
          last_cache_cleanup: non_neg_integer(),
          cache_table: atom()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the AgentActivityMonitor server.
  
  ## Options
  - `:config` - A Config struct (required)
  - `:name` - GenServer name (overrides config.name)
  
  ## Examples
  
      # With minimal config
      config = AgentActivityMonitor.Config.minimal("/tmp/sessions")
      {:ok, pid} = Server.start_link(config: config)
      
      # With named server
      config = AgentActivityMonitor.Config.new("/tmp/sessions", name: MyMonitor)
      {:ok, _pid} = Server.start_link(config: config)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
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
  
  Returns a list of agent activity maps sorted by last_activity (most recent first).
  
  ## Examples
  
      # With a pid
      activities = Server.get_activity(pid)
      
      # With a named server
      activities = Server.get_activity(MyApp.AgentMonitor)
  """
  @spec get_activity(GenServer.server()) :: list(SessionParser.agent_activity())
  def get_activity(server) do
    GenServer.call(server, :get_activity, 5_000)
  end

  @doc """
  Subscribe to agent activity updates via PubSub.
  
  Only works if the server was configured with a pubsub option.
  
  When subscribed, you'll receive messages of the form:
  `{:agent_activity, [%{id: _, status: _, ...}, ...]}`
  
  ## Example
  
      :ok = Server.subscribe(MyApp.AgentMonitor)
      
      # In handle_info:
      def handle_info({:agent_activity, activities}, state) do
        # Process activities...
      end
  """
  @spec subscribe(GenServer.server()) :: :ok | {:error, :no_pubsub_configured}
  def subscribe(server) do
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
  def get_config(server) do
    GenServer.call(server, :get_config, 1_000)
  end

  @doc """
  Force an immediate poll (useful for testing).
  """
  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server) do
    send(server, :poll)
    :ok
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    # Create unique ETS table for this server instance
    cache_table = create_cache_table(config.name)
    
    schedule_poll(config.poll_interval_ms)
    schedule_cache_cleanup(config.cache_cleanup_interval_ms)
    schedule_gc(config.gc_interval_ms)
    
    default_state = %{
      config: config,
      agents: %{},
      session_offsets: %{},
      last_poll: nil,
      polling: false,
      last_cache_cleanup: System.system_time(:millisecond),
      cache_table: cache_table
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
        fix_loaded_state(loaded, config, cache_table)
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
  def terminate(_reason, state) do
    # Clean up ETS table on termination
    try do
      :ets.delete(state.cache_table)
    rescue
      _ -> :ok
    end
    :ok
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
    cleanup_transcript_cache(state.cache_table, state.config.max_cache_entries)
    schedule_cache_cleanup(state.config.cache_cleanup_interval_ms)
    {:noreply, %{state | last_cache_cleanup: System.system_time(:millisecond)}}
  end

  @impl true
  def handle_info(:gc_trigger, state) do
    # Use configured gc_trigger callback or default to erlang:garbage_collect
    case state.config.gc_trigger do
      nil -> :erlang.garbage_collect()
      gc_fn when is_function(gc_fn, 1) -> gc_fn.(__MODULE__)
    end
    schedule_gc(state.config.gc_interval_ms)
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_cache_table(nil) do
    # Generate unique table name for unnamed servers
    table_name = :"transcript_cache_#{:erlang.unique_integer([:positive])}"
    :ets.new(table_name, [:named_table, :set, :public])
    table_name
  end

  defp create_cache_table(name) when is_atom(name) do
    table_name = :"#{name}_transcript_cache"
    # Delete existing table if it exists (for restarts)
    try do
      :ets.delete(table_name)
    rescue
      _ -> :ok
    end
    :ets.new(table_name, [:named_table, :set, :public])
    table_name
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp schedule_cache_cleanup(interval_ms) do
    Process.send_after(self(), :cleanup_cache, interval_ms)
  end

  defp schedule_gc(interval_ms) do
    Process.send_after(self(), :gc_trigger, interval_ms)
  end

  defp cleanup_transcript_cache(cache_table, max_entries) do
    try do
      all_entries = :ets.tab2list(cache_table)
      entry_count = length(all_entries)
      
      if entry_count > max_entries do
        Logger.info("AgentActivityMonitor: Cleaning cache, #{entry_count} entries")
        
        sorted_entries = Enum.sort_by(all_entries, fn {_path, mtime, _agent} -> mtime end)
        entries_to_remove = Enum.take(sorted_entries, entry_count - max_entries)
        
        for {path, _mtime, _agent} <- entries_to_remove do
          :ets.delete(cache_table, path)
        end
        
        Logger.info("AgentActivityMonitor: Removed #{length(entries_to_remove)} cache entries")
      end
    rescue
      e ->
        Logger.warning("AgentActivityMonitor: Cache cleanup failed: #{inspect(e)}")
    end
  end

  defp fix_loaded_state(loaded, config, cache_table) do
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
      last_cache_cleanup: System.system_time(:millisecond),
      cache_table: cache_table
    }
  end

  defp poll_agent_activity(state) do
    config = state.config
    
    # Parse OpenClaw sessions
    {openclaw_agents, new_offsets} = parse_openclaw_sessions(state)
    
    # Optionally get process-based agents
    process_agents = if config.monitor_processes? && config.find_processes do
      config.find_processes.(config.cli_timeout_ms)
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
    case safe_cache_lookup(state.cache_table, path, mtime) do
      {:hit, cached_agent} ->
        cached_agent
        
      {:miss, _reason} ->
        parse_and_cache_session(path, filename, mtime, state)
    end
  end

  defp safe_cache_lookup(cache_table, path, expected_mtime) do
    try do
      case :ets.lookup(cache_table, path) do
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
        safe_cache_insert(state.cache_table, path, mtime, agent)
        
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

  defp safe_cache_insert(cache_table, path, mtime, agent) do
    try do
      :ets.insert(cache_table, {path, mtime, agent})
    rescue
      e ->
        Logger.warning("AgentActivityMonitor: Failed to cache result for #{path}: #{inspect(e)}")
    end
  end
end
