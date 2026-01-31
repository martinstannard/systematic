defmodule DashboardPhoenixWeb.HomeLiveCache do
  @moduledoc """
  Memoization cache for expensive operations in HomeLive.
  
  Uses ETS for fast lookups and fingerprinting of input data to detect when 
  cached values need to be recomputed.
  """
  
  use GenServer
  
  @table_name :home_live_cache
  @max_cache_size 100
  @ttl_ms 30_000  # 30 seconds TTL for cache entries
  
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end
  
  @impl true
  def init(_) do
    table = :ets.new(@table_name, [:set, :public, :named_table])
    {:ok, %{table: table}}
  end
  
  @doc """
  Get a cached result for build_agent_activity or compute and cache it.
  """
  def get_agent_activity(sessions, progress) do
    key = {:agent_activity, fingerprint(sessions), fingerprint(progress)}
    
    case get_cached(key) do
      {:hit, result} -> result
      :miss ->
        result = compute_agent_activity(sessions, progress)
        cache_result(key, result)
        result
    end
  end
  
  @doc """
  Get a cached result for build_graph_data or compute and cache it.
  """
  def get_graph_data(sessions, coding_agents, processes, opencode_sessions, gemini_status) do
    key = {:graph_data, 
           fingerprint(sessions), 
           fingerprint(coding_agents), 
           fingerprint(processes), 
           fingerprint(opencode_sessions), 
           fingerprint(gemini_status)}
    
    case get_cached(key) do
      {:hit, result} -> result
      :miss ->
        result = compute_graph_data(sessions, coding_agents, processes, opencode_sessions, gemini_status)
        cache_result(key, result)
        result
    end
  end
  
  @doc """
  Clear the entire cache.
  """
  def clear_cache do
    GenServer.call(__MODULE__, :clear)
  end
  
  # Private functions
  
  defp ensure_table_exists do
    case :ets.whereis(@table_name) do
      :undefined ->
        # Table doesn't exist, try to recreate it
        try do
          :ets.new(@table_name, [:set, :public, :named_table])
          :ok
        rescue
          ArgumentError ->
            # Another process might have created it between whereis and new
            case :ets.whereis(@table_name) do
              :undefined -> :error
              _ -> :ok
            end
        end
      _ ->
        # Table exists
        :ok
    end
  end
  
  defp safe_ets_insert(data) do
    try do
      :ets.insert(@table_name, data)
    rescue
      ArgumentError -> :ok  # Table doesn't exist, skip caching
    end
  end
  
  defp safe_ets_delete(key) do
    try do
      :ets.delete(@table_name, key)
    rescue
      ArgumentError -> :ok  # Table doesn't exist, that's fine
    end
  end
  
  defp get_cached(key) do
    case ensure_table_exists() do
      :ok ->
        case :ets.lookup(@table_name, key) do
          [{^key, result, inserted_at}] ->
            if System.monotonic_time(:millisecond) - inserted_at < @ttl_ms do
              {:hit, result}
            else
              safe_ets_delete(key)
              :miss
            end
          [] ->
            :miss
        end
      :error ->
        # If we can't ensure the table exists, skip caching and return miss
        :miss
    end
  end
  
  defp cache_result(key, result) do
    case ensure_table_exists() do
      :ok ->
        # Cleanup old entries if cache is getting too big
        cleanup_cache_if_needed()
        
        # Insert new entry with timestamp
        safe_ets_insert({key, result, System.monotonic_time(:millisecond)})
      :error ->
        # If we can't ensure the table exists, skip caching
        :ok
    end
  end
  
  defp cleanup_cache_if_needed do
    try do
      case :ets.info(@table_name, :size) do
        size when size >= @max_cache_size ->
          # Remove oldest entries (this is a simple cleanup strategy)
          all_entries = :ets.tab2list(@table_name)
          sorted_by_time = Enum.sort_by(all_entries, fn {_, _, time} -> time end)
          
          # Remove oldest 25% of entries
          to_remove = Enum.take(sorted_by_time, div(size, 4))
          Enum.each(to_remove, fn {key, _, _} ->
            safe_ets_delete(key)
          end)
        _ ->
          :ok
      end
    rescue
      ArgumentError -> :ok  # Table doesn't exist, nothing to clean up
    end
  end
  
  # Create a fingerprint of the input data
  # This is a fast hash that changes when the underlying data changes
  defp fingerprint(data) when is_list(data) do
    # For lists, use length + hash of first/last few elements
    case data do
      [] -> 
        {:empty, 0}
      [single] -> 
        {:single, hash_item(single)}
      _ ->
        first_few = Enum.take(data, 3)
        last_few = Enum.take(data, -3)
        {length(data), hash_item(first_few), hash_item(last_few)}
    end
  end
  
  defp fingerprint(data) when is_map(data) do
    # For maps/structs, hash a few key fields
    map_size = map_size(data)
    key_fields = data |> Map.keys() |> Enum.take(5)
    values = Enum.map(key_fields, fn k -> Map.get(data, k) end)
    {map_size, hash_item(key_fields), hash_item(values)}
  end
  
  defp fingerprint(data) do
    # For other data types, just hash directly
    hash_item(data)
  end
  
  defp hash_item(item) do
    :crypto.hash(:sha256, :erlang.term_to_binary(item))
    |> Base.encode16()
    |> String.slice(0, 16)  # Use first 16 chars for performance
  end
  
  # Compute functions (extracted from HomeLive)
  
  defp compute_agent_activity(sessions, progress) do
    # Group progress events by agent
    events_by_agent = Enum.group_by(progress, & &1.agent)
    
    # Build activity for each running/active session
    sessions
    |> Enum.filter(fn s -> s.status in ["running", "idle"] end)
    |> Enum.map(fn session ->
      agent_id = session.label || session.id
      agent_events = Map.get(events_by_agent, agent_id, [])
      
      # Get recent actions
      recent = agent_events |> Enum.take(-10)
      last = List.last(recent)
      
      # Extract files from recent events
      files = recent
      |> Enum.map(& &1.target)
      |> Enum.filter(& &1 && String.contains?(&1, "/"))
      |> Enum.uniq()
      |> Enum.take(-5)
      
      %{
        id: session.id,
        type: determine_agent_type(session),
        model: session.model,
        cwd: nil,
        status: if(session.status == "running", do: "active", else: "idle"),
        last_action: if(last, do: %{action: last.action, target: last.target}, else: nil),
        files_worked: files,
        last_activity: if(last, do: parse_event_time(last.ts), else: nil),
        tool_call_count: length(agent_events)
      }
    end)
    |> Enum.filter(fn a -> a.tool_call_count > 0 end)
  end
  
  defp determine_agent_type(session) do
    session_key = Map.get(session, :session_key)
    cond do
      session_key && String.contains?(session_key, "main:main") -> :openclaw
      session_key && String.contains?(session_key, "subagent") -> :openclaw
      true -> :openclaw
    end
  end
  
  defp parse_event_time(ts) when is_integer(ts), do: DateTime.from_unix!(ts, :millisecond)
  defp parse_event_time(_), do: DateTime.utc_now()
  
  defp compute_graph_data(sessions, coding_agents, processes, opencode_sessions, gemini_status) do
    nodes = []
    links = []
    
    # Main node (OpenClaw)
    main_node = %{
      id: "main",
      label: "OpenClaw",
      type: "main",
      status: "running"
    }
    nodes = [main_node | nodes]
    
    # Sub-agent nodes (Claude sub-agents)
    {subagent_nodes, subagent_links} = 
      sessions
      |> Enum.filter(fn s -> s.session_key != "agent:main:main" end)
      |> Enum.take(8)  # Limit for readability
      |> Enum.map(fn session ->
        node = %{
          id: "subagent-#{session.id}",
          label: session.label || "subagent",
          type: "subagent",
          status: session.status
        }
        link = %{
          source: "main",
          target: "subagent-#{session.id}",
          type: "spawned"
        }
        {node, link}
      end)
      |> Enum.unzip()
    
    nodes = nodes ++ subagent_nodes
    links = links ++ subagent_links
    
    # OpenCode session nodes
    {opencode_nodes, opencode_links} =
      opencode_sessions
      |> Enum.take(6)
      |> Enum.map(fn session ->
        node = %{
          id: "opencode-#{session.id}",
          label: session.slug || session.title || "opencode",
          type: "opencode",
          status: if(session.status in ["active", "running"], do: "running", else: "idle")
        }
        link = %{
          source: "main",
          target: "opencode-#{session.id}",
          type: "spawned"
        }
        {node, link}
      end)
      |> Enum.unzip()
    
    nodes = nodes ++ opencode_nodes
    links = links ++ opencode_links
    
    # Gemini agent node (if running)
    {gemini_nodes, gemini_links} = if gemini_status.running do
      node = %{
        id: "gemini-main",
        label: "Gemini CLI",
        type: "gemini",
        status: "running"
      }
      link = %{
        source: "main",
        target: "gemini-main",
        type: "spawned"
      }
      {[node], [link]}
    else
      {[], []}
    end
    
    nodes = nodes ++ gemini_nodes
    links = links ++ gemini_links
    
    # Coding agent nodes (legacy process-based agents)
    {coding_nodes, coding_links} =
      coding_agents
      |> Enum.take(6)
      |> Enum.map(fn agent ->
        node = %{
          id: "coding-#{agent.pid}",
          label: "#{agent.type}",
          type: "coding_agent",
          status: if(agent.status == "running", do: "running", else: "idle")
        }
        link = %{
          source: "main",
          target: "coding-#{agent.pid}",
          type: "monitors"
        }
        {node, link}
      end)
      |> Enum.unzip()
    
    nodes = nodes ++ coding_nodes
    links = links ++ coding_links
    
    # System process nodes (just a few key ones)
    {process_nodes, process_links} =
      processes
      |> Enum.filter(fn p -> p.status == "busy" end)
      |> Enum.take(4)
      |> Enum.map(fn proc ->
        node = %{
          id: "proc-#{proc.pid}",
          label: proc.name || "process",
          type: "system",
          status: proc.status
        }
        link = %{
          source: "main",
          target: "proc-#{proc.pid}",
          type: "monitors"
        }
        {node, link}
      end)
      |> Enum.unzip()
    
    nodes = nodes ++ process_nodes
    links = links ++ process_links
    
    %{nodes: nodes, links: links}
  end
  
  @impl true
  def handle_call(:clear, _from, state) do
    try do
      :ets.delete_all_objects(@table_name)
    rescue
      ArgumentError -> :ok  # Table doesn't exist, nothing to clear
    end
    {:reply, :ok, state}
  end
end