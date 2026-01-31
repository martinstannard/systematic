defmodule DashboardPhoenixWeb.HomeLive do
  use DashboardPhoenixWeb, :live_view
  
  alias DashboardPhoenix.ProcessMonitor
  alias DashboardPhoenix.SessionBridge
  alias DashboardPhoenix.StatsMonitor
  alias DashboardPhoenix.ResourceTracker
  alias DashboardPhoenix.AgentActivityMonitor
  alias DashboardPhoenix.CodingAgentMonitor
  alias DashboardPhoenix.LinearMonitor
  alias DashboardPhoenix.AgentPreferences
  alias DashboardPhoenix.OpenCodeServer
  alias DashboardPhoenix.OpenCodeClient

  def mount(_params, _session, socket) do
    if connected?(socket) do
      SessionBridge.subscribe()
      StatsMonitor.subscribe()
      ResourceTracker.subscribe()
      AgentActivityMonitor.subscribe()
      AgentPreferences.subscribe()
      LinearMonitor.subscribe()
      OpenCodeServer.subscribe()
      Process.send_after(self(), :update_processes, 100)
      :timer.send_interval(2_000, :update_processes)
      :timer.send_interval(5_000, :refresh_opencode_sessions)
    end

    processes = ProcessMonitor.list_processes()
    sessions = SessionBridge.get_sessions()
    progress = SessionBridge.get_progress()
    stats = StatsMonitor.get_stats()
    resource_history = ResourceTracker.get_history()
    agent_activity = build_agent_activity(sessions, progress)
    coding_agents = CodingAgentMonitor.list_agents()
    coding_agent_pref = AgentPreferences.get_coding_agent()
    linear_data = LinearMonitor.get_tickets()
    opencode_status = OpenCodeServer.status()
    opencode_sessions = fetch_opencode_sessions(opencode_status)
    
    graph_data = build_graph_data(sessions, coding_agents, processes)
    
    # Calculate main session activity count for warning
    main_activity_count = Enum.count(progress, & &1.agent == "main")
    
    socket = assign(socket,
      process_stats: ProcessMonitor.get_stats(processes),
      recent_processes: processes,
      agent_sessions: sessions,
      agent_progress: progress,
      usage_stats: stats,
      resource_history: resource_history,
      agent_activity: agent_activity,
      coding_agents: coding_agents,
      graph_data: graph_data,
      dismissed_sessions: MapSet.new(),  # Track dismissed session IDs
      show_main_entries: true,            # Toggle for main session visibility
      show_completed: true,               # Toggle for completed sub-agents visibility
      main_activity_count: main_activity_count,
      expanded_outputs: MapSet.new(),     # Track which outputs are expanded
      coding_agent_pref: coding_agent_pref,  # Coding agent preference (opencode/claude)
      linear_tickets: linear_data.tickets,
      linear_last_updated: linear_data.last_updated,
      linear_error: linear_data.error,
      # Work modal state
      show_work_modal: false,
      work_ticket_id: nil,
      work_ticket_details: nil,
      work_ticket_loading: false,
      # OpenCode server state
      opencode_server_status: opencode_status,
      opencode_sessions: opencode_sessions,
      # Work in progress
      work_in_progress: false,
      work_error: nil,
      # Panel collapse states
      linear_collapsed: false,
      opencode_collapsed: false,
      coding_agents_collapsed: false,
      subagents_collapsed: false,
      live_progress_collapsed: false,
      agent_activity_collapsed: false,
      system_processes_collapsed: false,
      process_relationships_collapsed: false
    )
    
    socket = if connected?(socket) do
      push_event(socket, "graph_update", graph_data)
    else
      socket
    end

    {:ok, socket}
  end

  # Handle live progress updates
  def handle_info({:progress, events}, socket) do
    updated = (socket.assigns.agent_progress ++ events) |> Enum.take(-100)
    activity = build_agent_activity(socket.assigns.agent_sessions, updated)
    main_activity_count = Enum.count(updated, & &1.agent == "main")
    {:noreply, assign(socket, agent_progress: updated, agent_activity: activity, main_activity_count: main_activity_count)}
  end

  # Handle session updates
  def handle_info({:sessions, sessions}, socket) do
    activity = build_agent_activity(sessions, socket.assigns.agent_progress)
    {:noreply, assign(socket, agent_sessions: sessions, agent_activity: activity)}
  end

  # Handle stats updates
  def handle_info({:stats_updated, stats}, socket) do
    {:noreply, assign(socket, usage_stats: stats)}
  end

  # Handle resource tracker updates
  def handle_info({:resource_update, %{history: history}}, socket) do
    {:noreply, assign(socket, resource_history: history)}
  end

  # Handle agent activity updates - rebuild from sessions + progress
  def handle_info({:agent_activity, _activities}, socket) do
    # Rebuild activity from current data
    activity = build_agent_activity(socket.assigns.agent_sessions, socket.assigns.agent_progress)
    {:noreply, assign(socket, agent_activity: activity)}
  end

  # Handle agent preferences updates
  def handle_info({:preferences_updated, prefs}, socket) do
    {:noreply, assign(socket, coding_agent_pref: String.to_atom(prefs.coding_agent))}
  end

  # Handle Linear ticket updates
  def handle_info({:linear_update, data}, socket) do
    {:noreply, assign(socket,
      linear_tickets: data.tickets,
      linear_last_updated: data.last_updated,
      linear_error: data.error
    )}
  end

  # Handle OpenCode server status updates
  def handle_info({:opencode_status, status}, socket) do
    sessions = fetch_opencode_sessions(status)
    {:noreply, assign(socket, opencode_server_status: status, opencode_sessions: sessions)}
  end

  # Handle periodic OpenCode sessions refresh
  def handle_info(:refresh_opencode_sessions, socket) do
    if socket.assigns.opencode_server_status.running do
      sessions = fetch_opencode_sessions(socket.assigns.opencode_server_status)
      {:noreply, assign(socket, opencode_sessions: sessions)}
    else
      {:noreply, socket}
    end
  end

  # Handle async work result (from OpenCode or OpenClaw)
  def handle_info({:work_result, result}, socket) do
    case result do
      {:ok, %{session_id: session_id}} ->
        socket = socket
        |> assign(work_in_progress: false, work_error: nil)
        |> put_flash(:info, "Task sent to OpenCode (session: #{session_id})")
        {:noreply, socket}
      
      {:ok, %{ticket_id: ticket_id}} ->
        socket = socket
        |> assign(work_in_progress: false, work_error: nil)
        |> put_flash(:info, "Work request sent to OpenClaw for #{ticket_id}")
        {:noreply, socket}
      
      {:error, reason} ->
        socket = socket
        |> assign(work_in_progress: false, work_error: "Failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # Handle async ticket details fetch
  def handle_info({:fetch_ticket_details, ticket_id}, socket) do
    details = case LinearMonitor.get_ticket_details(ticket_id) do
      {:ok, output} -> output
      {:error, reason} -> "Error fetching details: #{reason}"
    end
    
    {:noreply, assign(socket,
      work_ticket_details: details,
      work_ticket_loading: false
    )}
  end

  def handle_info(:update_processes, socket) do
    processes = ProcessMonitor.list_processes()
    coding_agents = CodingAgentMonitor.list_agents()
    sessions = socket.assigns.agent_sessions
    graph_data = build_graph_data(sessions, coding_agents, processes)
    
    socket = socket
    |> assign(
      process_stats: ProcessMonitor.get_stats(processes),
      recent_processes: processes,
      coding_agents: coding_agents,
      graph_data: graph_data
    )
    |> push_event("graph_update", graph_data)
    
    {:noreply, socket}
  end

  def handle_event("kill_agent", %{"id" => _id}, socket) do
    socket = put_flash(socket, :info, "Kill not implemented for sub-agents yet")
    {:noreply, socket}
  end

  def handle_event("kill_process", %{"pid" => pid}, socket) do
    case CodingAgentMonitor.kill_agent(pid) do
      :ok ->
        coding_agents = CodingAgentMonitor.list_agents()
        socket = socket
        |> assign(coding_agents: coding_agents)
        |> put_flash(:info, "Process #{pid} terminated")
        {:noreply, socket}
      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to kill process: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("clear_progress", _, socket) do
    progress_file = Application.get_env(:dashboard_phoenix, :progress_file, "/tmp/agent-progress.jsonl")
    File.write(progress_file, "")
    {:noreply, assign(socket, agent_progress: [], main_activity_count: 0)}
  end

  def handle_event("toggle_main_entries", _, socket) do
    {:noreply, assign(socket, show_main_entries: !socket.assigns.show_main_entries)}
  end

  def handle_event("toggle_show_completed", _, socket) do
    {:noreply, assign(socket, show_completed: !socket.assigns.show_completed)}
  end

  def handle_event("toggle_output", %{"ts" => ts_str}, socket) do
    ts = String.to_integer(ts_str)
    expanded = socket.assigns.expanded_outputs
    new_expanded = if MapSet.member?(expanded, ts) do
      MapSet.delete(expanded, ts)
    else
      MapSet.put(expanded, ts)
    end
    {:noreply, assign(socket, expanded_outputs: new_expanded)}
  end

  def handle_event("refresh_stats", _, socket) do
    StatsMonitor.refresh()
    {:noreply, socket}
  end

  def handle_event("refresh_linear", _, socket) do
    LinearMonitor.refresh()
    {:noreply, socket}
  end

  def handle_event("toggle_linear_panel", _, socket) do
    {:noreply, assign(socket, linear_collapsed: !socket.assigns.linear_collapsed)}
  end

  def handle_event("toggle_panel", %{"panel" => panel}, socket) do
    key = String.to_existing_atom(panel <> "_collapsed")
    {:noreply, assign(socket, key, !Map.get(socket.assigns, key))}
  end

  def handle_event("work_on_ticket", %{"id" => ticket_id}, socket) do
    # Show modal immediately with loading state
    socket = assign(socket,
      show_work_modal: true,
      work_ticket_id: ticket_id,
      work_ticket_details: nil,
      work_ticket_loading: true
    )
    
    # Fetch ticket details async
    send(self(), {:fetch_ticket_details, ticket_id})
    
    {:noreply, socket}
  end

  def handle_event("close_work_modal", _, socket) do
    {:noreply, assign(socket,
      show_work_modal: false,
      work_ticket_id: nil,
      work_ticket_details: nil,
      work_ticket_loading: false
    )}
  end

  def handle_event("copy_spawn_command", _, socket) do
    # The actual copy happens via JS hook, this is just for feedback
    {:noreply, put_flash(socket, :info, "Command copied to clipboard!")}
  end

  def handle_event("toggle_coding_agent", _, socket) do
    AgentPreferences.toggle_coding_agent()
    new_pref = AgentPreferences.get_coding_agent()
    {:noreply, assign(socket, coding_agent_pref: new_pref)}
  end

  # OpenCode server controls
  def handle_event("start_opencode_server", _, socket) do
    case OpenCodeServer.start_server() do
      {:ok, port} ->
        socket = socket
        |> assign(opencode_server_status: OpenCodeServer.status())
        |> put_flash(:info, "OpenCode server started on port #{port}")
        {:noreply, socket}
      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start OpenCode server: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("stop_opencode_server", _, socket) do
    OpenCodeServer.stop_server()
    socket = socket
    |> assign(opencode_server_status: OpenCodeServer.status())
    |> put_flash(:info, "OpenCode server stopped")
    {:noreply, socket}
  end

  def handle_event("refresh_opencode_sessions", _, socket) do
    sessions = fetch_opencode_sessions(socket.assigns.opencode_server_status)
    {:noreply, assign(socket, opencode_sessions: sessions)}
  end

  # Execute work on ticket using OpenCode or OpenClaw
  def handle_event("execute_work", _, socket) do
    ticket_id = socket.assigns.work_ticket_id
    ticket_details = socket.assigns.work_ticket_details
    coding_pref = socket.assigns.coding_agent_pref
    
    cond do
      # If OpenCode mode is selected
      coding_pref == :opencode ->
        # Build the prompt from ticket details
        prompt = """
        Work on ticket #{ticket_id}.
        
        Ticket details:
        #{ticket_details || "No details available - use the ticket ID to look it up."}
        
        Please analyze this ticket and implement the required changes.
        """
        
        # Start work in background
        parent = self()
        Task.start(fn ->
          result = OpenCodeClient.send_task(prompt)
          send(parent, {:work_result, result})
        end)
        
        socket = socket
        |> assign(work_in_progress: true, work_error: nil)
        |> put_flash(:info, "Starting work with OpenCode...")
        {:noreply, socket}
      
      # Claude mode - send to OpenClaw to spawn a sub-agent
      true ->
        alias DashboardPhoenix.OpenClawClient
        
        # Start work in background
        parent = self()
        Task.start(fn ->
          result = OpenClawClient.work_on_ticket(ticket_id, ticket_details)
          send(parent, {:work_result, result})
        end)
        
        socket = socket
        |> assign(work_in_progress: true, work_error: nil, show_work_modal: false)
        |> put_flash(:info, "Sending work request to OpenClaw...")
        {:noreply, socket}
    end
  end

  def handle_event("dismiss_session", %{"id" => id}, socket) do
    dismissed = MapSet.put(socket.assigns.dismissed_sessions, id)
    {:noreply, assign(socket, dismissed_sessions: dismissed)}
  end

  def handle_event("clear_completed", _, socket) do
    # Get all completed session IDs and add them to dismissed
    completed_ids = socket.assigns.agent_sessions
    |> Enum.filter(fn s -> s.status == "completed" end)
    |> Enum.map(fn s -> s.id end)
    
    dismissed = Enum.reduce(completed_ids, socket.assigns.dismissed_sessions, fn id, acc ->
      MapSet.put(acc, id)
    end)
    
    {:noreply, assign(socket, dismissed_sessions: dismissed)}
  end

  # Build agent activity from sessions and progress events
  defp build_agent_activity(sessions, progress) do
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
    cond do
      session.session_key && String.contains?(session.session_key, "main:main") -> :openclaw
      session.session_key && String.contains?(session.session_key, "subagent") -> :openclaw
      true -> :openclaw
    end
  end

  defp parse_event_time(ts) when is_integer(ts), do: DateTime.from_unix!(ts, :millisecond)
  defp parse_event_time(_), do: DateTime.utc_now()

  # Build graph data for relationship visualization
  defp build_graph_data(sessions, coding_agents, processes) do
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
    
    # Sub-agent nodes
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
    
    # Coding agent nodes
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

  # Fetch OpenCode sessions if server is running
  defp fetch_opencode_sessions(%{running: true}) do
    case OpenCodeClient.list_sessions_formatted() do
      {:ok, sessions} -> sessions
      {:error, _} -> []
    end
  end
  defp fetch_opencode_sessions(_), do: []

  defp format_time(nil), do: ""
  defp format_time(ts) when is_integer(ts) do
    ts
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end
  defp format_time(_), do: ""

  defp agent_color("main"), do: "text-yellow-500 font-semibold"  # Yellow to indicate "should offload"
  defp agent_color("cron"), do: "text-gray-400"
  defp agent_color(name) when is_binary(name) do
    cond do
      String.contains?(name, "systematic") -> "text-purple-400"
      String.contains?(name, "dashboard") -> "text-purple-400"
      String.contains?(name, "cor-") or String.contains?(name, "fre-") -> "text-orange-400"
      true -> "text-accent"
    end
  end
  defp agent_color(_), do: "text-accent"

  defp action_color("Read"), do: "text-info"
  defp action_color("Edit"), do: "text-warning"
  defp action_color("Write"), do: "text-warning"
  defp action_color("Bash"), do: "text-accent"
  defp action_color("Search"), do: "text-primary"
  defp action_color("Think"), do: "text-secondary"
  defp action_color("Done"), do: "text-success"
  defp action_color("Error"), do: "text-error"
  defp action_color(_), do: "text-base-content/70"

  defp status_badge("running"), do: "bg-warning/20 text-warning animate-pulse"
  defp status_badge("idle"), do: "bg-info/20 text-info"
  defp status_badge("completed"), do: "bg-success/20 text-success/60"
  defp status_badge("done"), do: "bg-success/20 text-success"
  defp status_badge("error"), do: "bg-error/20 text-error"
  defp status_badge(_), do: "bg-base-content/10 text-base-content/60"

  defp model_badge(model) when is_binary(model) do
    cond do
      String.contains?(model, "opus") -> "bg-purple-500/20 text-purple-400"
      String.contains?(model, "sonnet") -> "bg-orange-500/20 text-orange-400"
      String.contains?(model, "gemini") -> "bg-blue-500/20 text-blue-400"
      String.contains?(model, "opencode") -> "bg-green-500/20 text-green-400"
      true -> "bg-base-content/10 text-base-content/60"
    end
  end
  defp model_badge(_), do: "bg-base-content/10 text-base-content/60"

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n) when is_integer(n), do: "#{n}"
  defp format_tokens(_), do: "0"

  # Generate SVG sparkline from history data
  defp sparkline(history, type) do
    # history is [{timestamp, cpu, memory}, ...] - newest first
    values = history
    |> Enum.reverse()  # oldest first for drawing
    |> Enum.map(fn {_ts, cpu, mem} -> if type == :cpu, do: cpu, else: mem / 1024 end)  # mem in MB
    |> Enum.take(-30)  # Last 30 points
    
    if length(values) < 2 do
      ""
    else
      max_val = max(Enum.max(values), 1)
      width = 60
      height = 16
      
      points = values
      |> Enum.with_index()
      |> Enum.map(fn {val, i} ->
        x = i * (width / max(length(values) - 1, 1))
        y = height - (val / max_val * height)
        "#{Float.round(x, 1)},#{Float.round(y, 1)}"
      end)
      |> Enum.join(" ")
      
      color = if type == :cpu, do: "#60a5fa", else: "#34d399"
      
      """
      <svg width="#{width}" height="#{height}" class="inline-block">
        <polyline fill="none" stroke="#{color}" stroke-width="1.5" points="#{points}"/>
      </svg>
      """
    end
  end

  defp format_activity_time(nil), do: ""
  defp format_activity_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)
    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(dt, "%H:%M")
    end
  end
  defp format_activity_time(_), do: ""

  defp agent_type_icon(:openclaw), do: "🦞"
  defp agent_type_icon(:claude_code), do: "🤖"
  defp agent_type_icon(:opencode), do: "💻"
  defp agent_type_icon(:codex), do: "📝"
  defp agent_type_icon(_), do: "⚡"

  defp activity_status_color("executing"), do: "text-warning animate-pulse"
  defp activity_status_color("thinking"), do: "text-info animate-pulse"
  defp activity_status_color("processing"), do: "text-primary"
  defp activity_status_color("active"), do: "text-success"
  defp activity_status_color("busy"), do: "text-warning"
  defp activity_status_color(_), do: "text-base-content/50"

  defp format_linear_time(nil), do: ""
  defp format_linear_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)
    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(dt, "%H:%M")
    end
  end
  defp format_linear_time(_), do: ""

  defp linear_status_badge("Triage"), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-[10px]"
  defp linear_status_badge("Todo"), do: "px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-[10px]"
  defp linear_status_badge("Backlog"), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]"
  defp linear_status_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  defp opencode_status_badge("active"), do: "px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 text-[10px] animate-pulse"
  defp opencode_status_badge("subagent"), do: "px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-400 text-[10px]"
  defp opencode_status_badge("idle"), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]"
  defp opencode_status_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <!-- Header -->
      <div class="glass-panel rounded-lg px-4 py-2 flex items-center justify-between">
        <div class="flex items-center space-x-4">
          <h1 class="text-sm font-bold tracking-widest text-base-content">SYSTEMATIC</h1>
          <span class="text-[10px] text-base-content/60 font-mono">AGENT CONTROL</span>
          
          <!-- Theme Toggle -->
          <button
            id="theme-toggle"
            phx-hook="ThemeToggle"
            class="p-1.5 rounded-lg bg-base-content/10 hover:bg-base-content/20 transition-colors"
            title="Toggle light/dark mode"
          >
            <!-- Sun icon (shown in dark mode, click for light) -->
            <svg class="sun-icon w-4 h-4 text-yellow-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" />
            </svg>
            <!-- Moon icon (shown in light mode, click for dark) -->
            <svg class="moon-icon w-4 h-4 text-indigo-400" style="display: none;" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />
            </svg>
          </button>
        </div>
        
        <!-- Coding Agent Toggle + OpenCode Server Status -->
        <div class="flex items-center space-x-4">
          <!-- Coding Agent Selector -->
          <div class="flex items-center space-x-2">
            <span class="text-[10px] font-mono text-base-content/50 uppercase">Coding Agent:</span>
            <button 
              phx-click="toggle_coding_agent"
              class={"flex items-center space-x-2 px-3 py-1.5 rounded-lg transition-all duration-200 " <> 
                if(@coding_agent_pref == :opencode, 
                  do: "bg-blue-500/20 border border-blue-500/40 hover:bg-blue-500/30",
                  else: "bg-purple-500/20 border border-purple-500/40 hover:bg-purple-500/30"
                )}
              title="Click to toggle between OpenCode (Gemini) and Claude sub-agents"
            >
              <%= if @coding_agent_pref == :opencode do %>
                <span class="text-lg">💻</span>
                <span class="text-xs font-mono font-bold text-blue-400">OpenCode</span>
                <span class="text-[9px] font-mono text-blue-400/60">(Gemini)</span>
              <% else %>
                <span class="text-lg">🤖</span>
                <span class="text-xs font-mono font-bold text-purple-400">Claude</span>
                <span class="text-[9px] font-mono text-purple-400/60">(Sub-agents)</span>
              <% end %>
            </button>
          </div>
          
          <!-- OpenCode Server Status (shown when OpenCode mode is selected) -->
          <%= if @coding_agent_pref == :opencode do %>
            <div class="flex items-center space-x-2 border-l border-white/20 pl-4">
              <span class="text-[10px] font-mono text-base-content/50 uppercase">ACP Server:</span>
              <%= if @opencode_server_status.running do %>
                <div class="flex items-center space-x-2">
                  <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
                  <span class="text-[10px] font-mono text-success">Running</span>
                  <span class="text-[9px] font-mono text-base-content/40">:<%=@opencode_server_status.port %></span>
                  <button 
                    phx-click="stop_opencode_server"
                    class="text-[10px] font-mono px-2 py-0.5 rounded bg-error/20 text-error hover:bg-error/40"
                  >
                    Stop
                  </button>
                </div>
              <% else %>
                <div class="flex items-center space-x-2">
                  <span class="w-2 h-2 rounded-full bg-base-content/30"></span>
                  <span class="text-[10px] font-mono text-base-content/50">Stopped</span>
                  <button 
                    phx-click="start_opencode_server"
                    class="text-[10px] font-mono px-2 py-0.5 rounded bg-success/20 text-success hover:bg-success/40"
                  >
                    Start
                  </button>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
        
        <div class="flex items-center space-x-4 text-xs font-mono">
          <span class="text-success font-bold"><%= length(@agent_sessions) %></span>
          <span class="text-base-content/60">AGENTS</span>
          <span class="text-primary font-bold"><%= length(@agent_progress) %></span>
          <span class="text-base-content/60">EVENTS</span>
        </div>
      </div>

      <!-- Usage Stats -->
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <!-- OpenCode Stats -->
        <div class="glass-panel rounded-lg p-3">
          <div class="flex items-center justify-between mb-2">
            <span class="text-[10px] font-mono text-accent uppercase tracking-wider">📊 OpenCode (Gemini)</span>
            <button phx-click="refresh_stats" class="text-[10px] text-base-content/40 hover:text-accent">↻</button>
          </div>
          <%= if @usage_stats.opencode[:error] do %>
            <div class="text-xs text-base-content/40">Unavailable</div>
          <% else %>
            <div class="space-y-1 text-xs font-mono">
              <div class="flex justify-between">
                <span class="text-base-content/60">Sessions</span>
                <span class="text-white font-bold"><%= @usage_stats.opencode[:sessions] || 0 %></span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Input</span>
                <span class="text-primary"><%= @usage_stats.opencode[:input_tokens] || "0" %></span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Output</span>
                <span class="text-secondary"><%= @usage_stats.opencode[:output_tokens] || "0" %></span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Cost</span>
                <span class="text-success"><%= @usage_stats.opencode[:total_cost] || "$0" %></span>
              </div>
            </div>
          <% end %>
        </div>

        <!-- Claude Stats -->
        <div class="glass-panel rounded-lg p-3">
          <div class="text-[10px] font-mono text-accent uppercase tracking-wider mb-2">📊 Claude Code</div>
          <%= if @usage_stats.claude[:error] do %>
            <div class="text-xs text-base-content/40">Unavailable</div>
          <% else %>
            <div class="space-y-1 text-xs font-mono">
              <div class="flex justify-between">
                <span class="text-base-content/60">Sessions</span>
                <span class="text-white font-bold"><%= @usage_stats.claude[:sessions] || 0 %></span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Input</span>
                <span class="text-primary"><%= @usage_stats.claude[:input_tokens] || "0" %></span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Output</span>
                <span class="text-secondary"><%= @usage_stats.claude[:output_tokens] || "0" %></span>
              </div>
              <div class="flex justify-between">
                <span class="text-base-content/60">Cache</span>
                <span class="text-accent"><%= @usage_stats.claude[:cache_read] || "0" %></span>
              </div>
            </div>
          <% end %>
        </div>

        <!-- Quick Stats -->
        <div class="glass-panel rounded-lg p-3 lg:col-span-2">
          <div class="text-[10px] font-mono text-accent uppercase tracking-wider mb-2">📈 Summary</div>
          <div class="grid grid-cols-2 gap-4 text-xs font-mono">
            <div>
              <div class="text-base-content/60 mb-1">Total Sessions</div>
              <div class="text-2xl font-bold text-white">
                <%= (@usage_stats.opencode[:sessions] || 0) + (@usage_stats.claude[:sessions] || 0) %>
              </div>
            </div>
            <div>
              <div class="text-base-content/60 mb-1">Total Messages</div>
              <div class="text-2xl font-bold text-white">
                <%= (@usage_stats.opencode[:messages] || 0) + (@usage_stats.claude[:messages] || 0) %>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Linear Tickets Panel -->
      <div class="space-y-3">
        <div 
          class="flex items-center justify-between px-1 cursor-pointer select-none hover:opacity-80 transition-opacity"
          phx-click="toggle_linear_panel"
        >
          <div class="flex items-center space-x-3">
            <span class={"text-xs transition-transform duration-200 " <> if(@linear_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
            <span class="text-xs font-mono text-accent uppercase tracking-wider">🎫 Linear Tickets (COR)</span>
            <span class="text-[10px] font-mono text-base-content/50">
              <%= length(@linear_tickets) %> tickets
            </span>
          </div>
          <div class="flex items-center space-x-2">
            <%= if @linear_last_updated do %>
              <span class="text-[10px] font-mono text-base-content/40">
                Updated <%= format_linear_time(@linear_last_updated) %>
              </span>
            <% end %>
            <button phx-click="refresh_linear" class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">↻</button>
          </div>
        </div>
        
        <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@linear_collapsed, do: "max-h-0 opacity-0", else: "max-h-[2000px] opacity-100")}>
          <%= if @linear_error do %>
            <div class="glass-panel rounded-lg p-4 text-center">
              <div class="text-error text-xs"><%= @linear_error %></div>
            </div>
          <% else %>
            <%= if @linear_tickets == [] do %>
              <div class="glass-panel rounded-lg p-4 text-center">
                <div class="text-base-content/40 font-mono text-xs">[NO TICKETS]</div>
                <div class="text-base-content/60 text-xs">No tickets in Triage, Backlog, or Todo</div>
              </div>
            <% else %>
              <div class="glass-panel rounded-lg p-3">
                <div class="overflow-x-auto">
                  <table class="w-full text-xs font-mono">
                    <thead>
                      <tr class="text-base-content/50 border-b border-white/10">
                        <th class="text-left py-2 px-2 w-16"></th>
                        <th class="text-left py-2 px-2 w-24">ID</th>
                        <th class="text-left py-2 px-2">Title</th>
                        <th class="text-left py-2 px-2 w-20">Status</th>
                        <th class="text-left py-2 px-2 w-32">Project</th>
                        <th class="text-left py-2 px-2 w-24">Assignee</th>
                      </tr>
                    </thead>
                    <tbody>
                      <%= for ticket <- @linear_tickets do %>
                        <tr class="border-b border-white/5 hover:bg-white/5 transition-colors">
                          <td class="py-2 px-2">
                            <button
                              phx-click="work_on_ticket"
                              phx-value-id={ticket.id}
                              class="px-2 py-1 rounded bg-accent/20 text-accent hover:bg-accent/40 transition-colors text-[10px] font-bold"
                              title="Work on this ticket"
                            >
                              ▶ Work
                            </button>
                          </td>
                          <td class="py-2 px-2">
                            <a 
                              href={ticket.url} 
                              target="_blank" 
                              class="text-accent hover:text-accent/80 hover:underline"
                            >
                              <%= ticket.id %>
                            </a>
                          </td>
                          <td class="py-2 px-2 text-white truncate max-w-xs" title={ticket.title}>
                            <%= ticket.title %>
                          </td>
                          <td class="py-2 px-2">
                            <span class={linear_status_badge(ticket.status)}>
                              <%= ticket.status %>
                            </span>
                          </td>
                          <td class="py-2 px-2 text-base-content/60 truncate max-w-[120px]" title={ticket.project}>
                            <%= ticket.project || "-" %>
                          </td>
                          <td class="py-2 px-2">
                            <%= if ticket.assignee == "you" do %>
                              <span class="text-success font-semibold">you</span>
                            <% else %>
                              <span class="text-base-content/50"><%= ticket.assignee || "-" %></span>
                            <% end %>
                          </td>
                        </tr>
                      <% end %>
                    </tbody>
                  </table>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <!-- OpenCode Sessions Panel -->
      <div class="space-y-3">
        <div 
          class="flex items-center justify-between px-1 cursor-pointer select-none hover:opacity-80 transition-opacity"
          phx-click="toggle_panel"
          phx-value-panel="opencode"
        >
          <div class="flex items-center space-x-3">
            <span class={"text-xs transition-transform duration-200 " <> if(@opencode_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
            <span class="text-xs font-mono text-accent uppercase tracking-wider">💻 OpenCode Sessions</span>
            <span class="text-[10px] font-mono text-base-content/50">
              <%= length(@opencode_sessions) %> sessions
            </span>
          </div>
          <div class="flex items-center space-x-2">
            <button phx-click="refresh_opencode_sessions" class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">↻</button>
          </div>
        </div>
        
        <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@opencode_collapsed, do: "max-h-0 opacity-0", else: "max-h-[2000px] opacity-100")}>
        <%= if not @opencode_server_status.running do %>
          <div class="glass-panel rounded-lg p-4 text-center">
            <div class="text-base-content/40 font-mono text-xs mb-2">[SERVER NOT RUNNING]</div>
            <div class="text-base-content/60 text-xs mb-3">Start the OpenCode ACP server to see sessions</div>
            <button 
              phx-click="start_opencode_server"
              class="px-3 py-1.5 rounded bg-success/20 text-success hover:bg-success/40 text-xs font-mono"
            >
              Start Server
            </button>
          </div>
        <% else %>
          <%= if @opencode_sessions == [] do %>
            <div class="glass-panel rounded-lg p-4 text-center">
              <div class="text-base-content/40 font-mono text-xs">[NO SESSIONS]</div>
              <div class="text-base-content/60 text-xs">No active OpenCode sessions</div>
            </div>
          <% else %>
            <div class="glass-panel rounded-lg p-3">
              <div class="overflow-x-auto">
                <table class="w-full text-xs font-mono">
                  <thead>
                    <tr class="text-base-content/50 border-b border-white/10">
                      <th class="text-left py-2 px-2 w-28">Slug</th>
                      <th class="text-left py-2 px-2">Title</th>
                      <th class="text-left py-2 px-2 w-20">Status</th>
                      <th class="text-left py-2 px-2 w-24">Created</th>
                      <th class="text-left py-2 px-2 w-28">Changes</th>
                      <th class="text-left py-2 px-2 w-20"></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for session <- @opencode_sessions do %>
                      <tr class="border-b border-white/5 hover:bg-white/5 transition-colors">
                        <td class="py-2 px-2">
                          <span class={"font-semibold " <> if(session.parent_id, do: "text-purple-400", else: "text-blue-400")}>
                            <%= if session.parent_id do %>↳ <% end %><%= session.slug %>
                          </span>
                        </td>
                        <td class="py-2 px-2 text-white truncate max-w-xs" title={session.title}>
                          <%= session.title || "-" %>
                        </td>
                        <td class="py-2 px-2">
                          <span class={opencode_status_badge(session.status)}>
                            <%= session.status %>
                          </span>
                        </td>
                        <td class="py-2 px-2 text-base-content/60">
                          <%= format_linear_time(session.created_at) %>
                        </td>
                        <td class="py-2 px-2">
                          <%= if session.file_changes.files > 0 do %>
                            <span class="text-green-400">+<%= session.file_changes.additions %></span>
                            <span class="text-red-400">-<%= session.file_changes.deletions %></span>
                            <span class="text-base-content/50">(<%= session.file_changes.files %> files)</span>
                          <% else %>
                            <span class="text-base-content/40">-</span>
                          <% end %>
                        </td>
                        <td class="py-2 px-2">
                          <a 
                            href={"http://localhost:9100/session/#{session.id}"} 
                            target="_blank" 
                            class="px-2 py-1 rounded bg-blue-500/20 text-blue-400 hover:bg-blue-500/40 transition-colors text-[10px]"
                          >
                            View ↗
                          </a>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          <% end %>
        <% end %>
        </div>
      </div>

      <!-- Coding Agents (OpenCode, Claude Code, etc.) -->
      <%= if @coding_agents != [] do %>
        <div class="space-y-3">
          <div class="flex items-center px-1">
            <span class="text-xs font-mono text-accent uppercase tracking-wider">💻 Coding Agents</span>
          </div>
          <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-3">
            <%= for agent <- @coding_agents do %>
              <div class={"glass-panel rounded-lg p-3 border-l-4 " <> if(agent.status == "running", do: "border-l-warning", else: "border-l-success")}>
                <!-- Header -->
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center space-x-2">
                    <%= if agent.status == "running" do %>
                      <span class="throbber"></span>
                    <% else %>
                      <span class="text-base-content/50">○</span>
                    <% end %>
                    <span class="text-sm font-mono text-white font-bold"><%= agent.type %></span>
                  </div>
                  <button 
                    phx-click="kill_process" 
                    phx-value-pid={agent.pid}
                    class="text-[10px] font-mono px-2 py-0.5 rounded bg-error/20 text-error hover:bg-error/40 transition-colors"
                  >
                    KILL
                  </button>
                </div>
                
                <!-- Project / Working Dir -->
                <%= if agent.project do %>
                  <div class="text-xs font-mono text-accent mb-1"><%= agent.project %></div>
                <% end %>
                <%= if agent.working_dir do %>
                  <div class="text-[10px] font-mono text-base-content/50 mb-2 truncate" title={agent.working_dir}>
                    📁 <%= agent.working_dir %>
                  </div>
                <% end %>
                
                <!-- Stats -->
                <div class="flex items-center justify-between text-[10px] font-mono text-base-content/60">
                  <span>PID: <%= agent.pid %></span>
                  <span class="text-blue-400">CPU: <%= agent.cpu %>%</span>
                  <span class="text-green-400">MEM: <%= agent.memory %>%</span>
                </div>
                
                <!-- Runtime -->
                <div class="flex items-center justify-between text-[10px] font-mono text-base-content/50 mt-1">
                  <span>Started: <%= agent.started %></span>
                  <span>⏱ <%= agent.runtime %></span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- Agent Sessions Panel -->
      <div class="space-y-3">
        <div class="flex items-center justify-between px-1">
          <span class="text-xs font-mono text-accent uppercase tracking-wider">🤖 Sub-Agents</span>
          <div class="flex items-center space-x-2">
            <% completed_count = Enum.count(@agent_sessions, fn s -> 
              s.status == "completed" && !MapSet.member?(@dismissed_sessions, s.id) 
            end) %>
            <!-- Toggle show/hide completed -->
            <%= if completed_count > 0 do %>
              <button 
                phx-click="toggle_show_completed"
                class={"text-[10px] font-mono px-2 py-0.5 rounded transition-colors " <> if(@show_completed, do: "bg-success/20 text-success", else: "bg-base-content/10 text-base-content/40")}
                title={if @show_completed, do: "Click to hide completed sub-agents", else: "Click to show completed sub-agents"}
              >
                <%= if @show_completed, do: "👁 COMPLETED", else: "👁‍🗨 SHOW " <> Integer.to_string(completed_count) %> 
              </button>
              <button 
                phx-click="clear_completed" 
                class="text-[10px] font-mono px-2 py-0.5 rounded bg-base-content/10 text-base-content/60 hover:bg-base-content/20"
              >
                CLEAR (<%= completed_count %>)
              </button>
            <% end %>
          </div>
        </div>
        
        <% visible_sessions = @agent_sessions
          |> Enum.reject(fn s -> MapSet.member?(@dismissed_sessions, s.id) end)
          |> Enum.reject(fn s -> !@show_completed && s.status == "completed" end) %>
        <%= if visible_sessions == [] do %>
          <div class="glass-panel rounded-lg p-4 text-center">
            <div class="text-base-content/40 font-mono text-xs mb-2">[NO ACTIVE AGENTS]</div>
            <div class="text-base-content/60 text-xs">Spawn a sub-agent to begin</div>
          </div>
        <% else %>
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-3">
            <%= for session <- visible_sessions do %>
              <% status = Map.get(session, :status, "unknown") %>
              <% is_completed = status == "completed" %>
              <div class={"glass-panel rounded-lg p-3 border-l-4 " <> cond do
                status == "running" -> "border-l-warning"
                status == "idle" -> "border-l-info"
                true -> "border-l-success/50"
              end}>
                <!-- Header -->
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center space-x-2">
                    <%= if status == "running" do %>
                      <span class="throbber"></span>
                    <% else %>
                      <span class={if is_completed, do: "text-success/60", else: "text-info"}>
                        <%= if is_completed, do: "✓", else: "○" %>
                      </span>
                    <% end %>
                    <span class={"text-sm font-mono font-bold " <> if(is_completed, do: "text-white/60", else: "text-white")}>
                      <%= Map.get(session, :label) || Map.get(session, :id, "unknown") %>
                    </span>
                  </div>
                  <div class="flex items-center space-x-2">
                    <span class={"text-[10px] font-mono px-1.5 py-0.5 rounded " <> status_badge(status)}>
                      <%= String.upcase(status) %>
                    </span>
                    <%= if is_completed do %>
                      <button 
                        phx-click="dismiss_session" 
                        phx-value-id={session.id}
                        class="text-base-content/40 hover:text-error text-sm leading-none"
                        title="Dismiss"
                      >✕</button>
                    <% end %>
                  </div>
                </div>
                
                <!-- Agent Info Row -->
                <div class="flex items-center flex-wrap gap-2 mb-2">
                  <span class={"text-[10px] font-mono px-1.5 py-0.5 rounded " <> model_badge(Map.get(session, :model))}>
                    <%= String.upcase(to_string(Map.get(session, :model, "claude"))) %>
                  </span>
                  <%= if Map.get(session, :runtime) do %>
                    <span class={"text-[10px] font-mono " <> if(is_completed, do: "text-base-content/50", else: "text-warning")}>
                      ⏱ <%= Map.get(session, :runtime) %><%= if !is_completed, do: " so far" %>
                    </span>
                  <% end %>
                  <%= if is_completed && Map.get(session, :completed_at) do %>
                    <span class="text-[10px] font-mono text-base-content/40">
                      @ <%= Map.get(session, :completed_at) %>
                    </span>
                  <% end %>
                  <%= if !is_completed && Map.get(session, :completed_at) do %>
                    <span class="text-[10px] font-mono text-base-content/40">
                      started <%= Map.get(session, :completed_at) %>
                    </span>
                  <% end %>
                </div>
                
                <!-- Task Summary (shown for all sessions) -->
                <%= if Map.get(session, :task_summary) do %>
                  <div class="mb-2">
                    <div class="text-[10px] font-mono text-base-content/50 mb-0.5">Task:</div>
                    <div class="text-xs text-base-content/70 line-clamp-2"><%= Map.get(session, :task_summary) %></div>
                  </div>
                <% end %>
                
                <!-- Current Action (for running sessions) -->
                <% current_action = Map.get(session, :current_action) %>
                <%= if !is_completed && current_action do %>
                  <div class="mb-2">
                    <div class="text-[10px] font-mono text-base-content/50 mb-0.5">Currently:</div>
                    <div class="text-xs text-warning flex items-center space-x-1">
                      <span class="inline-block w-1.5 h-1.5 bg-warning rounded-full animate-ping"></span>
                      <span class="truncate"><%= current_action %></span>
                    </div>
                  </div>
                <% end %>
                
                <!-- Recent Actions (for running sessions) -->
                <% recent_actions = Map.get(session, :recent_actions, []) %>
                <%= if !is_completed && length(recent_actions) > 0 do %>
                  <div class="mb-2">
                    <div class="text-[10px] font-mono text-base-content/50 mb-0.5">Recent (<%= length(recent_actions) %> calls):</div>
                    <div class="text-[10px] font-mono text-base-content/50 space-y-0.5 max-h-16 overflow-y-auto">
                      <%= for action <- Enum.take(recent_actions, -3) do %>
                        <div class="truncate">✓ <%= action %></div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
                
                <!-- Result Snippet (for completed only) -->
                <%= if is_completed && Map.get(session, :result_snippet) do %>
                  <div class="mb-2">
                    <div class="text-[10px] font-mono text-base-content/50 mb-0.5">Result:</div>
                    <div class="text-xs text-success/70 line-clamp-2 italic"><%= Map.get(session, :result_snippet) %></div>
                  </div>
                <% end %>
                
                <!-- Token Stats (shown for all sessions with usage) -->
                <% tokens_in = Map.get(session, :tokens_in, 0) %>
                <% tokens_out = Map.get(session, :tokens_out, 0) %>
                <% cost = Map.get(session, :cost, 0) %>
                <%= if (tokens_in > 0 || tokens_out > 0) do %>
                  <div class="flex items-center space-x-3 text-[10px] font-mono">
                    <span class="text-primary">↓<%= format_tokens(tokens_in) %></span>
                    <span class="text-secondary">↑<%= format_tokens(tokens_out) %></span>
                    <%= if cost && cost > 0 do %>
                      <span class="text-success">$<%= Float.round(cost, 3) %><%= if !is_completed, do: " so far" %></span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <!-- Live Progress Feed -->
      <div class="space-y-3">
        <div class="flex items-center justify-between px-1">
          <div class="flex items-center space-x-3">
            <span class="text-xs font-mono text-accent uppercase tracking-wider">📡 Live Progress</span>
            <!-- Main session warning -->
            <%= if @main_activity_count > 10 do %>
              <span class="text-[10px] font-mono px-2 py-0.5 rounded bg-warning/20 text-warning animate-pulse" title="Main session has lots of activity - consider offloading work to sub-agents">
                ⚠️ main: <%= @main_activity_count %> actions
              </span>
            <% end %>
          </div>
          <div class="flex items-center space-x-2">
            <!-- Toggle main entries -->
            <button 
              phx-click="toggle_main_entries" 
              class={"text-[10px] font-mono px-2 py-0.5 rounded transition-colors " <> if(@show_main_entries, do: "bg-green-500/20 text-green-400", else: "bg-base-content/10 text-base-content/40")}
              title={if @show_main_entries, do: "Click to hide main session entries", else: "Click to show main session entries"}
            >
              <%= if @show_main_entries, do: "👁 main", else: "🚫 main" %>
            </button>
            <button phx-click="clear_progress" class="text-[10px] font-mono px-2 py-0.5 rounded bg-base-content/10 text-base-content/60 hover:bg-base-content/20">
              CLEAR
            </button>
          </div>
        </div>
        
        <div class="glass-panel rounded-lg p-3 h-[400px] overflow-y-auto font-mono text-xs" id="progress-feed" phx-hook="ScrollBottom">
          <%= if @agent_progress == [] do %>
            <div class="text-base-content/40 text-center py-8">
              Waiting for agent activity...
            </div>
          <% else %>
            <% filtered_progress = if @show_main_entries, do: @agent_progress, else: Enum.reject(@agent_progress, & &1.agent == "main") %>
            <%= for event <- filtered_progress do %>
              <% is_main = event.agent == "main" %>
              <% has_output = event.output != "" and event.output != nil %>
              <% ts_int = if is_integer(event.ts), do: event.ts, else: 0 %>
              <% is_expanded = MapSet.member?(@expanded_outputs, ts_int) %>
              <div class={"py-1 border-b border-white/5 last:border-0 " <> if(is_main, do: "opacity-50", else: "")}>
                <div class="flex items-start space-x-2">
                  <span class="text-base-content/40 w-14 flex-shrink-0"><%= format_time(event.ts) %></span>
                  <span class={"w-28 flex-shrink-0 truncate " <> agent_color(event.agent)} title={event.agent}>
                    <%= if is_main, do: "⚠️ ", else: "" %><%= event.agent %>
                  </span>
                  <span class={"w-14 flex-shrink-0 font-bold " <> action_color(event.action)}><%= event.action %></span>
                  <span class="text-base-content/70 truncate flex-1" title={event.target}><%= event.target %></span>
                  <!-- Output summary + expand button -->
                  <%= if has_output do %>
                    <button 
                      phx-click="toggle_output" 
                      phx-value-ts={ts_int}
                      class="text-[9px] px-1.5 py-0.5 rounded bg-base-content/10 hover:bg-base-content/20 text-base-content/60 flex-shrink-0"
                      title="Click to expand/collapse output"
                    >
                      <%= if is_expanded, do: "▼", else: "▶" %> <%= event[:output_summary] || "output" %>
                    </button>
                  <% else %>
                    <%= if event.status == "running" do %>
                      <span class="text-[9px] text-warning animate-pulse flex-shrink-0">⏳</span>
                    <% end %>
                  <% end %>
                  <%= if event.status == "error" do %>
                    <span class="text-error flex-shrink-0">✗</span>
                  <% end %>
                </div>
                <!-- Expanded output -->
                <%= if has_output and is_expanded do %>
                  <div class="mt-1 ml-16 p-2 rounded bg-black/30 text-[10px] text-base-content/70 whitespace-pre-wrap break-all max-h-32 overflow-y-auto">
                    <%= event.output %>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>
      </div>

      <!-- Agent Activity - What's it doing? -->
      <%= if @agent_activity != [] do %>
        <div class="space-y-3">
          <div class="flex items-center px-1">
            <span class="text-xs font-mono text-accent uppercase tracking-wider">🔍 What's it doing?</span>
          </div>
          <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
            <%= for activity <- @agent_activity do %>
              <div class="glass-panel rounded-lg p-3 border-l-4 border-l-accent">
                <!-- Header -->
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center space-x-2">
                    <span class="text-lg"><%= agent_type_icon(activity.type) %></span>
                    <span class="text-sm font-mono text-white font-bold truncate"><%= activity.model || "Agent" %></span>
                  </div>
                  <span class={"text-[10px] font-mono font-bold " <> activity_status_color(activity.status)}>
                    <%= String.upcase(to_string(activity.status)) %>
                  </span>
                </div>
                
                <!-- Working directory -->
                <%= if activity.cwd do %>
                  <div class="text-[10px] font-mono text-base-content/50 mb-2 truncate">
                    📁 <%= activity.cwd %>
                  </div>
                <% end %>
                
                <!-- Last action -->
                <%= if activity.last_action do %>
                  <div class="text-xs font-mono mb-2 flex items-center space-x-2">
                    <span class={"font-bold " <> action_color(activity.last_action.action)}><%= activity.last_action.action %></span>
                    <%= if activity.last_action.target do %>
                      <span class="text-base-content/70 truncate flex-1"><%= activity.last_action.target %></span>
                    <% end %>
                  </div>
                <% end %>
                
                <!-- Files being worked on -->
                <%= if activity.files_worked != [] do %>
                  <div class="mb-2">
                    <div class="text-[10px] font-mono text-base-content/50 mb-1">Recent files:</div>
                    <div class="flex flex-wrap gap-1">
                      <%= for file <- Enum.take(activity.files_worked, 4) do %>
                        <span class="text-[9px] font-mono px-1.5 py-0.5 rounded bg-primary/20 text-primary truncate max-w-[150px]">
                          <%= Path.basename(file) %>
                        </span>
                      <% end %>
                      <%= if length(activity.files_worked) > 4 do %>
                        <span class="text-[9px] font-mono text-base-content/40">+<%= length(activity.files_worked) - 4 %></span>
                      <% end %>
                    </div>
                  </div>
                <% end %>
                
                <!-- Stats row -->
                <div class="flex items-center justify-between text-[10px] font-mono text-base-content/50">
                  <span><%= activity.tool_call_count || 0 %> tool calls</span>
                  <span><%= format_activity_time(activity.last_activity) %></span>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>

      <!-- System Processes with Sparklines -->
      <div class="space-y-3">
        <div class="flex items-center px-1">
          <span class="text-xs font-mono text-base-content/60 uppercase tracking-wider">⚙️ System Processes (<%= length(@recent_processes) %>)</span>
        </div>
        <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-3">
          <%= for process <- @recent_processes do %>
            <% history = Map.get(@resource_history, process.pid, []) %>
            <div class={"glass-panel rounded-lg p-3 border-l-4 " <> case process.status do
              "busy" -> "border-l-warning"
              "idle" -> "border-l-success"
              _ -> "border-l-base-content/20"
            end}>
              <div class="text-xs font-mono text-white bg-black/30 rounded px-2 py-1 mb-2 truncate">
                <span class="text-accent">$</span> <%= process.command %>
              </div>
              <div class="flex items-center justify-between text-[10px] font-mono mb-2">
                <span class="text-base-content/60"><%= process.name %></span>
                <span class="text-base-content/60">PID: <%= process.pid %></span>
              </div>
              <!-- Resource stats with sparklines -->
              <div class="flex items-center justify-between text-[10px] font-mono">
                <div class="flex items-center space-x-2">
                  <span class="text-blue-400">CPU:</span>
                  <span class="text-white"><%= Map.get(process, :cpu_usage, "?") %></span>
                  <%= if history != [] do %>
                    <%= Phoenix.HTML.raw(sparkline(history, :cpu)) %>
                  <% end %>
                </div>
                <div class="flex items-center space-x-2">
                  <span class="text-green-400">MEM:</span>
                  <span class="text-white"><%= Map.get(process, :memory_usage, "?") %></span>
                  <%= if history != [] do %>
                    <%= Phoenix.HTML.raw(sparkline(history, :memory)) %>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Relationship Graph -->
      <div class="space-y-3">
        <div class="flex items-center justify-between px-1">
          <span class="text-xs font-mono text-accent uppercase tracking-wider">🔗 Process Relationships</span>
          <div class="flex items-center space-x-4 text-[10px] font-mono">
            <span class="flex items-center space-x-1">
              <span class="w-3 h-3 rounded-full bg-green-600"></span>
              <span class="text-base-content/60">Main</span>
            </span>
            <span class="flex items-center space-x-1">
              <span class="w-3 h-3 rounded-full bg-purple-600"></span>
              <span class="text-base-content/60">Sub-Agent</span>
            </span>
            <span class="flex items-center space-x-1">
              <span class="w-3 h-3 rounded-full bg-orange-500"></span>
              <span class="text-base-content/60">Coding Agent</span>
            </span>
            <span class="flex items-center space-x-1">
              <span class="w-3 h-3 rounded-full bg-gray-500"></span>
              <span class="text-base-content/60">System</span>
            </span>
          </div>
        </div>
        <div class="glass-panel rounded-lg p-4">
          <div id="relationship-graph" phx-hook="RelationshipGraph" phx-update="ignore" class="w-full h-[300px]"></div>
        </div>
      </div>

      <!-- Work on Ticket Modal -->
      <%= if @show_work_modal do %>
        <div class="fixed inset-0 bg-black/60 flex items-center justify-center z-50" phx-click="close_work_modal">
          <div class="glass-panel rounded-lg p-6 max-w-3xl w-full mx-4 max-h-[80vh] overflow-y-auto" phx-click-away="close_work_modal">
            <!-- Header -->
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center space-x-3">
                <span class="text-2xl">🎫</span>
                <h2 class="text-lg font-bold text-white font-mono"><%= @work_ticket_id %></h2>
              </div>
              <button 
                phx-click="close_work_modal" 
                class="text-base-content/60 hover:text-white text-xl leading-none"
              >
                ✕
              </button>
            </div>
            
            <!-- Ticket Details -->
            <div class="mb-6">
              <div class="text-xs font-mono text-accent uppercase tracking-wider mb-2">Ticket Details</div>
              <%= if @work_ticket_loading do %>
                <div class="flex items-center space-x-2 text-base-content/60">
                  <span class="throbber"></span>
                  <span class="text-sm">Fetching ticket details...</span>
                </div>
              <% else %>
                <pre class="text-xs font-mono text-base-content/80 bg-black/40 rounded-lg p-4 whitespace-pre-wrap overflow-x-auto max-h-64 overflow-y-auto"><%= @work_ticket_details %></pre>
              <% end %>
            </div>
            
            <!-- Start Working Section -->
            <div class="border-t border-white/10 pt-4">
              <div class="flex items-center justify-between mb-3">
                <div class="text-xs font-mono text-accent uppercase tracking-wider">Start Working</div>
                <div class={"text-[10px] font-mono px-2 py-1 rounded " <> if(@coding_agent_pref == :opencode, do: "bg-blue-500/20 text-blue-400", else: "bg-purple-500/20 text-purple-400")}>
                  Using: <%= if @coding_agent_pref == :opencode, do: "💻 OpenCode", else: "🤖 Claude" %>
                </div>
              </div>
              
              <%= if @coding_agent_pref == :opencode do %>
                <!-- OpenCode Mode -->
                <div class="space-y-4">
                  <!-- Work Error -->
                  <%= if @work_error do %>
                    <div class="bg-error/20 text-error rounded-lg p-3 text-sm font-mono">
                      <%= @work_error %>
                    </div>
                  <% end %>
                  
                  <!-- Server Status Check -->
                  <%= if not @opencode_server_status.running do %>
                    <div class="bg-warning/20 text-warning rounded-lg p-3 text-sm">
                      ⚠️ OpenCode ACP server is not running. 
                      <button 
                        phx-click="start_opencode_server"
                        class="underline hover:no-underline ml-1"
                      >
                        Start it now
                      </button>
                    </div>
                  <% end %>
                  
                  <!-- Execute Work Button -->
                  <div class="flex items-center space-x-3">
                    <button
                      phx-click="execute_work"
                      disabled={@work_in_progress or @work_ticket_loading}
                      class={"flex-1 py-3 rounded-lg text-sm font-mono font-bold transition-all " <> 
                        if(@work_in_progress, 
                          do: "bg-blue-500/30 text-blue-300 cursor-wait",
                          else: "bg-blue-500/20 text-blue-400 hover:bg-blue-500/40"
                        )}
                    >
                      <%= if @work_in_progress do %>
                        <span class="inline-block animate-spin mr-2">⟳</span> Sending to OpenCode...
                      <% else %>
                        🚀 Execute Work with OpenCode
                      <% end %>
                    </button>
                  </div>
                  
                  <p class="text-[10px] text-base-content/50">
                    This will send the ticket details to the OpenCode ACP server and start working automatically.
                  </p>
                </div>
              <% else %>
                <!-- Claude Mode - Copy Command -->
                <div class="space-y-3">
                  <p class="text-sm text-base-content/70">
                    Copy the command below to spawn a Claude sub-agent that will work on this ticket:
                  </p>
                  
                  <% spawn_command = "Work on #{@work_ticket_id}" %>
                  <div class="relative">
                    <div 
                      id="spawn-command" 
                      class="text-sm font-mono bg-black/50 rounded-lg p-4 pr-16 text-green-400 cursor-pointer hover:bg-black/60 transition-colors"
                      phx-hook="CopyToClipboard"
                      data-copy={spawn_command}
                    >
                      <%= spawn_command %>
                    </div>
                    <button
                      class="absolute right-2 top-1/2 -translate-y-1/2 px-3 py-1.5 rounded bg-accent/20 text-accent hover:bg-accent/40 transition-colors text-xs font-mono"
                      phx-click="copy_spawn_command"
                      id="copy-btn"
                      phx-hook="CopyToClipboard"
                      data-copy={spawn_command}
                    >
                      📋 Copy
                    </button>
                  </div>
                  
                  <p class="text-[10px] text-base-content/50">
                    Tip: Paste this into your OpenClaw chat to spawn a sub-agent for this ticket.
                  </p>
                </div>
              <% end %>
            </div>
            
            <!-- Actions -->
            <div class="flex items-center justify-end space-x-3 mt-6 pt-4 border-t border-white/10">
              <a 
                href={"https://linear.app/fresh-clinics/issue/#{@work_ticket_id}"} 
                target="_blank"
                class="px-4 py-2 rounded bg-base-content/10 text-base-content/70 hover:bg-base-content/20 transition-colors text-sm font-mono"
              >
                Open in Linear ↗
              </a>
              <button 
                phx-click="close_work_modal"
                class="px-4 py-2 rounded bg-accent/20 text-accent hover:bg-accent/40 transition-colors text-sm font-mono"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
