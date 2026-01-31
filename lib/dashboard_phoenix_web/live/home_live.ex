defmodule DashboardPhoenixWeb.HomeLive do
  use DashboardPhoenixWeb, :live_view
  
  alias DashboardPhoenixWeb.Live.Components.LinearComponent
  alias DashboardPhoenix.ProcessMonitor
  alias DashboardPhoenix.SessionBridge
  alias DashboardPhoenix.StatsMonitor
  alias DashboardPhoenix.ResourceTracker
  alias DashboardPhoenix.AgentActivityMonitor
  alias DashboardPhoenix.CodingAgentMonitor
  alias DashboardPhoenix.LinearMonitor
  alias DashboardPhoenix.PRMonitor
  alias DashboardPhoenix.BranchMonitor
  alias DashboardPhoenix.AgentPreferences
  alias DashboardPhoenix.OpenCodeServer
  alias DashboardPhoenix.OpenCodeClient
  alias DashboardPhoenix.GeminiServer

  def mount(_params, _session, socket) do
    if connected?(socket) do
      SessionBridge.subscribe()
      StatsMonitor.subscribe()
      ResourceTracker.subscribe()
      AgentActivityMonitor.subscribe()
      AgentPreferences.subscribe()
      LinearMonitor.subscribe()
      PRMonitor.subscribe()
      BranchMonitor.subscribe()
      OpenCodeServer.subscribe()
      GeminiServer.subscribe()
      Process.send_after(self(), :update_processes, 100)
      :timer.send_interval(2_000, :update_processes)
      :timer.send_interval(5_000, :refresh_opencode_sessions)
      # Async load Linear tickets to avoid blocking mount
      send(self(), :load_linear_tickets)
      # Async load GitHub PRs
      send(self(), :load_github_prs)
      # Async load unmerged branches
      send(self(), :load_branches)
    end

    processes = ProcessMonitor.list_processes()
    sessions = SessionBridge.get_sessions()
    progress = SessionBridge.get_progress()
    stats = StatsMonitor.get_stats()
    resource_history = ResourceTracker.get_history()
    agent_activity = build_agent_activity(sessions, progress)
    coding_agents = CodingAgentMonitor.list_agents()
    coding_agent_pref = AgentPreferences.get_coding_agent()
    opencode_status = OpenCodeServer.status()
    opencode_sessions = fetch_opencode_sessions(opencode_status)
    gemini_status = GeminiServer.status()
    
    # Build map of ticket_id -> work session info
    tickets_in_progress = build_tickets_in_progress(opencode_sessions, sessions)
    
    graph_data = build_graph_data(sessions, coding_agents, processes, opencode_sessions, gemini_status)
    
    # Calculate main session activity count for warning
    main_activity_count = Enum.count(progress, & &1.agent == "main")
    
    # Load persisted PR state (tickets that have PRs created)
    pr_created_tickets = load_pr_state()
    
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
      show_main_entries: true,            # Toggle for main session visibility (legacy)
      progress_filter: "all",              # Filter: "all", "main", or specific agent name
      show_completed: true,               # Toggle for completed sub-agents visibility
      main_activity_count: main_activity_count,
      expanded_outputs: MapSet.new(),     # Track which outputs are expanded
      coding_agent_pref: coding_agent_pref,  # Coding agent preference (opencode/claude)
      # Linear tickets - loaded async to avoid blocking mount
      linear_tickets: [],
      linear_counts: %{},
      linear_last_updated: nil,
      linear_error: nil,
      linear_loading: true,
      linear_status_filter: "Todo",
      tickets_in_progress: tickets_in_progress,
      pr_created_tickets: pr_created_tickets,
      # GitHub PRs - loaded async to avoid blocking mount
      github_prs: [],
      github_prs_last_updated: nil,
      github_prs_error: nil,
      github_prs_loading: true,
      # Unmerged branches - loaded async
      unmerged_branches: [],
      branches_worktrees: %{},
      branches_last_updated: nil,
      branches_error: nil,
      branches_loading: true,
      # Branch action states
      branch_merge_pending: nil,
      branch_delete_pending: nil,
      # Work modal state
      show_work_modal: false,
      work_ticket_id: nil,
      work_ticket_details: nil,
      work_ticket_loading: false,
      # OpenCode server state
      opencode_server_status: opencode_status,
      opencode_sessions: opencode_sessions,
      # Gemini server state
      gemini_server_status: gemini_status,
      gemini_output: "",
      # Work in progress
      work_in_progress: false,
      work_sent: false,
      work_error: nil,
      # Model selections
      claude_model: "anthropic/claude-opus-4-5",  # Default to opus
      opencode_model: "gemini-3-pro",  # Default to gemini 3 pro
      # Panel collapse states
      config_collapsed: false,
      linear_collapsed: false,
      prs_collapsed: false,
      branches_collapsed: false,
      opencode_collapsed: false,
      gemini_collapsed: false,
      coding_agents_collapsed: false,
      subagents_collapsed: false,
      dave_collapsed: false,
      live_progress_collapsed: false,
      agent_activity_collapsed: false,
      system_processes_collapsed: false,
      process_relationships_collapsed: false,
      chat_collapsed: true
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
    tickets_in_progress = build_tickets_in_progress(socket.assigns.opencode_sessions, sessions)
    {:noreply, assign(socket, agent_sessions: sessions, agent_activity: activity, tickets_in_progress: tickets_in_progress)}
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

  # Handle LinearComponent messages
  def handle_info({:linear_component, :set_filter, status}, socket) do
    {:noreply, assign(socket, linear_status_filter: status)}
  end

  def handle_info({:linear_component, :toggle_panel}, socket) do
    socket = assign(socket, linear_collapsed: !socket.assigns.linear_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:linear_component, :refresh}, socket) do
    DashboardPhoenix.LinearMonitor.refresh()
    {:noreply, socket}
  end

  def handle_info({:linear_component, :work_on_ticket, ticket_id}, socket) do
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

  # Handle Linear ticket updates (from PubSub)
  def handle_info({:linear_update, data}, socket) do
    linear_counts = Enum.frequencies_by(data.tickets, & &1.status)
    {:noreply, assign(socket,
      linear_tickets: data.tickets,
      linear_counts: linear_counts,
      linear_last_updated: data.last_updated,
      linear_error: data.error,
      linear_loading: false
    )}
  end

  # Handle async Linear ticket loading (initial mount)
  def handle_info(:load_linear_tickets, socket) do
    # Fetch in a supervised Task to avoid blocking and catch crashes
    parent = self()
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        linear_data = LinearMonitor.get_tickets()
        send(parent, {:linear_loaded, linear_data})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load Linear tickets: #{inspect(e)}")
          send(parent, {:linear_loaded, %{tickets: [], last_updated: nil, error: "Load failed: #{inspect(e)}"}})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Linear tickets load exited: #{inspect(reason)}")
          send(parent, {:linear_loaded, %{tickets: [], last_updated: nil, error: "Load timeout"}})
      end
    end)
    {:noreply, socket}
  end

  # Handle Linear tickets loaded result
  def handle_info({:linear_loaded, data}, socket) do
    linear_counts = Enum.frequencies_by(data.tickets, & &1.status)
    {:noreply, assign(socket,
      linear_tickets: data.tickets,
      linear_counts: linear_counts,
      linear_last_updated: data.last_updated,
      linear_error: data.error,
      linear_loading: false
    )}
  end

  # Handle GitHub PR updates (from PubSub)
  def handle_info({:pr_update, data}, socket) do
    {:noreply, assign(socket,
      github_prs: data.prs,
      github_prs_last_updated: data.last_updated,
      github_prs_error: data.error,
      github_prs_loading: false
    )}
  end

  # Handle async GitHub PR loading (initial mount)
  def handle_info(:load_github_prs, socket) do
    # Fetch in a supervised Task to avoid blocking and catch crashes
    parent = self()
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        pr_data = PRMonitor.get_prs()
        send(parent, {:github_prs_loaded, pr_data})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load GitHub PRs: #{inspect(e)}")
          send(parent, {:github_prs_loaded, %{prs: [], last_updated: nil, error: "Load failed: #{inspect(e)}"}})
      catch
        :exit, reason ->
          require Logger
          Logger.error("GitHub PRs load exited: #{inspect(reason)}")
          send(parent, {:github_prs_loaded, %{prs: [], last_updated: nil, error: "Load timeout"}})
      end
    end)
    {:noreply, socket}
  end

  # Handle GitHub PRs loaded result
  def handle_info({:github_prs_loaded, data}, socket) do
    {:noreply, assign(socket,
      github_prs: data.prs,
      github_prs_last_updated: data.last_updated,
      github_prs_error: data.error,
      github_prs_loading: false
    )}
  end

  # Handle branch updates (from PubSub)
  def handle_info({:branch_update, data}, socket) do
    {:noreply, assign(socket,
      unmerged_branches: data.branches,
      branches_worktrees: data.worktrees,
      branches_last_updated: data.last_updated,
      branches_error: data.error,
      branches_loading: false
    )}
  end

  # Handle async branch loading (initial mount)
  def handle_info(:load_branches, socket) do
    parent = self()
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        branch_data = BranchMonitor.get_branches()
        send(parent, {:branches_loaded, branch_data})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load branches: #{inspect(e)}")
          send(parent, {:branches_loaded, %{branches: [], worktrees: %{}, last_updated: nil, error: "Load failed: #{inspect(e)}"}})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Branches load exited: #{inspect(reason)}")
          send(parent, {:branches_loaded, %{branches: [], worktrees: %{}, last_updated: nil, error: "Load timeout"}})
      end
    end)
    {:noreply, socket}
  end

  # Handle branches loaded result
  def handle_info({:branches_loaded, data}, socket) do
    {:noreply, assign(socket,
      unmerged_branches: data.branches,
      branches_worktrees: data.worktrees,
      branches_last_updated: data.last_updated,
      branches_error: data.error,
      branches_loading: false
    )}
  end

  # Handle branch merge result
  def handle_info({:branch_merge_result, branch_name, result}, socket) do
    case result do
      {:ok, _} ->
        socket = socket
        |> assign(branch_merge_pending: nil)
        |> put_flash(:info, "Successfully merged #{branch_name} to main")
        {:noreply, socket}
      
      {:error, reason} ->
        socket = socket
        |> assign(branch_merge_pending: nil)
        |> put_flash(:error, "Merge failed: #{reason}")
        {:noreply, socket}
    end
  end

  # Handle branch delete result
  def handle_info({:branch_delete_result, branch_name, result}, socket) do
    case result do
      {:ok, _} ->
        socket = socket
        |> assign(branch_delete_pending: nil)
        |> put_flash(:info, "Successfully deleted #{branch_name}")
        {:noreply, socket}
      
      {:error, reason} ->
        socket = socket
        |> assign(branch_delete_pending: nil)
        |> put_flash(:error, "Delete failed: #{reason}")
        {:noreply, socket}
    end
  end

  # Handle OpenCode server status updates
  def handle_info({:opencode_status, status}, socket) do
    sessions = fetch_opencode_sessions(status)
    tickets_in_progress = build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
    {:noreply, assign(socket, opencode_server_status: status, opencode_sessions: sessions, tickets_in_progress: tickets_in_progress)}
  end

  # Handle Gemini server status updates
  def handle_info({:gemini_status, status}, socket) do
    {:noreply, assign(socket, gemini_server_status: status)}
  end

  # Handle Gemini output updates
  def handle_info({:gemini_output, output}, socket) do
    # Append new output, keeping last 5000 chars
    new_output = socket.assigns.gemini_output <> output
    new_output = if String.length(new_output) > 5000 do
      String.slice(new_output, -5000..-1)
    else
      new_output
    end
    {:noreply, assign(socket, gemini_output: new_output)}
  end

  # Handle periodic OpenCode sessions refresh
  def handle_info(:refresh_opencode_sessions, socket) do
    if socket.assigns.opencode_server_status.running do
      sessions = fetch_opencode_sessions(socket.assigns.opencode_server_status)
      tickets_in_progress = build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
      {:noreply, assign(socket, opencode_sessions: sessions, tickets_in_progress: tickets_in_progress)}
    else
      {:noreply, socket}
    end
  end

  # Handle async work result (from OpenCode or OpenClaw)
  def handle_info({:work_result, result}, socket) do
    case result do
      {:ok, %{session_id: session_id}} ->
        socket = socket
        |> assign(work_in_progress: false, work_sent: true, work_error: nil)
        |> put_flash(:info, "Task sent to OpenCode (session: #{session_id})")
        {:noreply, socket}
      
      {:ok, %{ticket_id: ticket_id}} ->
        socket = socket
        |> assign(work_in_progress: false, work_sent: true, work_error: nil)
        |> put_flash(:info, "Work request sent to OpenClaw for #{ticket_id}")
        {:noreply, socket}
      
      {:error, reason} ->
        socket = socket
        |> assign(work_in_progress: false, work_sent: false, work_error: "Failed: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # Handle chat result
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
    opencode_sessions = socket.assigns.opencode_sessions
    gemini_status = socket.assigns.gemini_server_status
    graph_data = build_graph_data(sessions, coding_agents, processes, opencode_sessions, gemini_status)
    
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

  def handle_event("set_progress_filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, progress_filter: filter)}
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

  # NOTE: refresh_linear now handled via LinearComponent -> handle_info({:linear_component, :refresh}, ...)

  def handle_event("refresh_prs", _, socket) do
    PRMonitor.refresh()
    {:noreply, socket}
  end

  def handle_event("refresh_branches", _, socket) do
    BranchMonitor.refresh()
    {:noreply, socket}
  end

  def handle_event("confirm_merge_branch", %{"name" => branch_name}, socket) do
    {:noreply, assign(socket, branch_merge_pending: branch_name)}
  end

  def handle_event("cancel_merge_branch", _, socket) do
    {:noreply, assign(socket, branch_merge_pending: nil)}
  end

  def handle_event("execute_merge_branch", %{"name" => branch_name}, socket) do
    parent = self()
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      result = BranchMonitor.merge_branch(branch_name)
      send(parent, {:branch_merge_result, branch_name, result})
    end)
    {:noreply, assign(socket, branch_merge_pending: nil)}
  end

  def handle_event("confirm_delete_branch", %{"name" => branch_name}, socket) do
    {:noreply, assign(socket, branch_delete_pending: branch_name)}
  end

  def handle_event("cancel_delete_branch", _, socket) do
    {:noreply, assign(socket, branch_delete_pending: nil)}
  end

  def handle_event("execute_delete_branch", %{"name" => branch_name}, socket) do
    parent = self()
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      result = BranchMonitor.delete_branch(branch_name)
      send(parent, {:branch_delete_result, branch_name, result})
    end)
    {:noreply, assign(socket, branch_delete_pending: nil)}
  end

  # NOTE: set_linear_filter and toggle_linear_panel now handled via LinearComponent -> handle_info

  def handle_event("toggle_panel", %{"panel" => panel}, socket) do
    key = String.to_existing_atom(panel <> "_collapsed")
    socket = assign(socket, key, !Map.get(socket.assigns, key))
    {:noreply, push_panel_state(socket)}
  end

  # Restore panel state from localStorage via JS hook
  def handle_event("restore_panel_state", %{"panels" => panels}, socket) when is_map(panels) do
    socket = Enum.reduce(panels, socket, fn {panel, collapsed}, acc ->
      key = String.to_existing_atom(panel <> "_collapsed")
      assign(acc, key, collapsed)
    end)
    {:noreply, socket}
  end

  def handle_event("restore_panel_state", _, socket), do: {:noreply, socket}

  # NOTE: work_on_ticket now handled via LinearComponent -> handle_info({:linear_component, :work_on_ticket, ticket_id}, ...)
  # But we keep handle_event for backward compatibility with tests and direct phx-click usage
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
      work_ticket_loading: false,
      work_sent: false
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

  def handle_event("set_coding_agent", %{"agent" => agent}, socket) do
    AgentPreferences.set_coding_agent(agent)
    new_pref = AgentPreferences.get_coding_agent()
    {:noreply, assign(socket, coding_agent_pref: new_pref)}
  end

  def handle_event("select_claude_model", %{"model" => model}, socket) do
    socket = assign(socket, claude_model: model)
    {:noreply, push_model_selections(socket)}
  end

  def handle_event("select_opencode_model", %{"model" => model}, socket) do
    socket = assign(socket, opencode_model: model)
    {:noreply, push_model_selections(socket)}
  end

  # Restore model selections from localStorage via JS hook
  def handle_event("restore_model_selections", %{"claude_model" => claude_model, "opencode_model" => opencode_model}, socket) when is_binary(claude_model) and is_binary(opencode_model) do
    {:noreply, assign(socket, claude_model: claude_model, opencode_model: opencode_model)}
  end

  def handle_event("restore_model_selections", _, socket), do: {:noreply, socket}

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
    tickets_in_progress = build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
    {:noreply, assign(socket, opencode_sessions: sessions, tickets_in_progress: tickets_in_progress)}
  end

  # Gemini server controls
  def handle_event("start_gemini_server", _, socket) do
    case GeminiServer.start_server() do
      {:ok, _pid} ->
        socket = socket
        |> assign(gemini_server_status: GeminiServer.status())
        |> put_flash(:info, "Gemini CLI started")
        {:noreply, socket}
      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start Gemini: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_event("stop_gemini_server", _, socket) do
    GeminiServer.stop_server()
    socket = socket
    |> assign(gemini_server_status: GeminiServer.status(), gemini_output: "")
    |> put_flash(:info, "Gemini CLI stopped")
    {:noreply, socket}
  end

  def handle_event("send_gemini_prompt", %{"prompt" => prompt}, socket) when prompt != "" do
    case GeminiServer.send_prompt(prompt) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Prompt sent to Gemini")}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send: #{inspect(reason)}")}
    end
  end

  def handle_event("send_gemini_prompt", _, socket), do: {:noreply, socket}

  def handle_event("clear_gemini_output", _, socket) do
    {:noreply, assign(socket, gemini_output: "")}
  end

  def handle_event("close_opencode_session", %{"id" => session_id}, socket) do
    case OpenCodeClient.delete_session(session_id) do
      :ok ->
        sessions = fetch_opencode_sessions(socket.assigns.opencode_server_status)
        tickets_in_progress = build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
        socket = socket
        |> assign(opencode_sessions: sessions, tickets_in_progress: tickets_in_progress)
        |> put_flash(:info, "Session closed")
        {:noreply, socket}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to close session: #{reason}")}
    end
  end

  def handle_event("request_opencode_pr", %{"id" => session_id}, socket) do
    prompt = """
    The work looks complete. Please create a Pull Request with:
    1. A clear, descriptive title
    2. A detailed description explaining what was changed and why
    3. Any relevant context for reviewers

    Use `gh pr create` to create the PR.
    """

    case OpenCodeClient.send_message(session_id, prompt) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "PR requested for session")}
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to request PR: #{reason}")}
    end
  end

  # Request PR creation for a ticket that has active work
  def handle_event("request_ticket_pr", %{"id" => ticket_id}, socket) do
    work_info = Map.get(socket.assigns.tickets_in_progress, ticket_id)
    
    if work_info do
      pr_prompt = """
      The work on #{ticket_id} looks complete. Please create a Pull Request with:
      1. A clear, descriptive title referencing #{ticket_id}
      2. A detailed description explaining what was changed and why
      3. Include the Linear ticket link in the PR description
      
      Use `gh pr create` to create the PR. After creating the PR, report back with the PR URL.
      """

      result = case work_info.type do
        :opencode ->
          # Send to OpenCode session
          OpenCodeClient.send_message(work_info.session_id, pr_prompt)
        
        :subagent ->
          # Send to OpenClaw sub-agent via sessions_send
          alias DashboardPhoenix.OpenClawClient
          OpenClawClient.send_message(pr_prompt, channel: "webchat")
      end

      case result do
        {:ok, _} ->
          # Mark ticket as having PR requested
          pr_created = MapSet.put(socket.assigns.pr_created_tickets, ticket_id)
          save_pr_state(pr_created)
          
          socket = socket
          |> assign(pr_created_tickets: pr_created)
          |> put_flash(:info, "PR requested for #{ticket_id}")
          {:noreply, socket}
        
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to request PR: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "No active work found for #{ticket_id}")}
    end
  end

  # Request super review for a ticket that has a PR
  def handle_event("request_super_review", %{"id" => ticket_id}, socket) do
    review_prompt = """
    🔍 **Super Review Request for #{ticket_id}**
    
    Please perform a comprehensive code review for the PR related to ticket #{ticket_id}:
    
    1. Check out the PR branch
    2. Review all code changes for:
       - Code quality and best practices
       - Potential bugs or edge cases
       - Performance implications
       - Security concerns
       - Test coverage
    3. Verify the implementation matches the ticket requirements
    4. Leave detailed review comments on the PR
    5. Approve or request changes as appropriate
    
    Use `gh pr view` to find the PR and `gh pr diff` to see changes.
    """

    # Spawn an isolated sub-agent to do the review
    alias DashboardPhoenix.OpenClawClient
    
    case OpenClawClient.spawn_subagent(review_prompt,
      name: "ticket-review-#{ticket_id}",
      thinking: "medium",
      post_mode: "summary"
    ) do
      {:ok, %{job_id: job_id}} ->
        {:noreply, put_flash(socket, :info, "Review sub-agent spawned for #{ticket_id} (job: #{String.slice(job_id, 0, 8)}...)")}
      
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Review sub-agent spawned for #{ticket_id}")}
      
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn review agent: #{inspect(reason)}")}
    end
  end

  # Handle request_super_review when id parameter is missing
  def handle_event("request_super_review", _params, socket) do
    {:noreply, put_flash(socket, :error, "Missing ticket ID for super review request")}
  end

  # Request super review for a GitHub PR
  def handle_event("request_pr_super_review", %{"url" => pr_url, "number" => pr_number, "repo" => repo}, socket) do
    review_prompt = """
    🔍 **Super Review Request for PR ##{pr_number}**
    
    Please perform a comprehensive code review for this Pull Request:
    URL: #{pr_url}
    Repository: #{repo}
    
    1. Fetch and review the PR using `gh pr view #{pr_number} --repo #{repo}`
    2. Review the diff using `gh pr diff #{pr_number} --repo #{repo}`
    3. Check all code changes for:
       - Code quality and best practices
       - Potential bugs or edge cases
       - Performance implications
       - Security concerns
       - Test coverage
    4. Leave detailed review comments on the PR
    5. Approve or request changes as appropriate using `gh pr review`
    
    Be thorough but constructive in your feedback.
    """

    # Spawn an isolated sub-agent to do the review
    alias DashboardPhoenix.OpenClawClient
    
    case OpenClawClient.spawn_subagent(review_prompt,
      name: "pr-review-#{pr_number}",
      thinking: "medium",
      post_mode: "summary"
    ) do
      {:ok, %{job_id: job_id}} ->
        {:noreply, put_flash(socket, :info, "Review sub-agent spawned for PR ##{pr_number} (job: #{String.slice(job_id, 0, 8)}...)")}
      
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Review sub-agent spawned for PR ##{pr_number}")}
      
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn review agent: #{inspect(reason)}")}
    end
  end

  # Fix PR issues (CI failures and/or merge conflicts)
  def handle_event("fix_pr_issues", params, socket) do
    %{"url" => pr_url, "number" => pr_number, "repo" => repo, "branch" => branch} = params
    has_conflicts = params["has-conflicts"] == "true"
    ci_failing = params["ci-failing"] == "true"
    
    issues = []
    issues = if ci_failing, do: ["CI failures" | issues], else: issues
    issues = if has_conflicts, do: ["merge conflicts" | issues], else: issues
    issues_text = Enum.join(issues, " and ")
    
    fix_prompt = """
    🔧 **Fix #{issues_text} for PR ##{pr_number}**
    
    This Pull Request has #{issues_text}. Please fix them:
    URL: #{pr_url}
    Repository: #{repo}
    Branch: #{branch}
    
    Steps:
    1. First, check out the branch: `cd ~/code/core-platform && git fetch origin && git checkout #{branch}`
    #{if has_conflicts, do: "2. Resolve merge conflicts: `git fetch origin main && git merge origin/main` - fix any conflicts, then commit", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "3", else: "2"}. Get CI failure details: `gh pr checks #{pr_number} --repo #{repo}`", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "4", else: "3"}. Review the failing checks and fix the issues (tests, linting, type errors, etc.)", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "5", else: "4"}. Run tests locally to verify: `mix test`", else: ""}
    - Commit and push the fixes
    
    Focus on fixing the issues, not refactoring unrelated code.
    """

    # Spawn an isolated sub-agent to fix the issues
    alias DashboardPhoenix.OpenClawClient
    
    case OpenClawClient.spawn_subagent(fix_prompt,
      name: "pr-fix-#{pr_number}",
      thinking: "low",
      post_mode: "summary"
    ) do
      {:ok, %{job_id: job_id}} ->
        {:noreply, put_flash(socket, :info, "Fix sub-agent spawned for PR ##{pr_number} (job: #{String.slice(job_id, 0, 8)}...)")}
      
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Fix sub-agent spawned for PR ##{pr_number}")}
      
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn fix agent: #{inspect(reason)}")}
    end
  end

  # Clear PR state for a ticket (e.g., when PR is merged)
  def handle_event("clear_ticket_pr", %{"id" => ticket_id}, socket) do
    pr_created = MapSet.delete(socket.assigns.pr_created_tickets, ticket_id)
    save_pr_state(pr_created)
    {:noreply, assign(socket, pr_created_tickets: pr_created)}
  end

  # Execute work on ticket using OpenCode or OpenClaw
  def handle_event("execute_work", _, socket) do
    ticket_id = socket.assigns.work_ticket_id
    ticket_details = socket.assigns.work_ticket_details
    coding_pref = socket.assigns.coding_agent_pref
    claude_model = socket.assigns.claude_model
    opencode_model = socket.assigns.opencode_model
    
    # Check if work already exists for this ticket
    if Map.has_key?(socket.assigns.tickets_in_progress, ticket_id) do
      work_info = Map.get(socket.assigns.tickets_in_progress, ticket_id)
      agent_type = if work_info.type == :opencode, do: "OpenCode", else: "sub-agent"
      socket = socket
      |> assign(show_work_modal: false)
      |> put_flash(:error, "Work already in progress for #{ticket_id} (#{agent_type}: #{work_info[:slug] || work_info[:label]})")
      {:noreply, socket}
    else
      execute_work_for_ticket(socket, ticket_id, ticket_details, coding_pref, claude_model, opencode_model)
    end
  end

  def handle_event("dismiss_session", %{"id" => id}, socket) do
    dismissed = MapSet.put(socket.assigns.dismissed_sessions, id)
    {:noreply, assign(socket, dismissed_sessions: dismissed)}
  end

  # Chat panel removed - using OpenClaw Control UI instead

  # Chat mode toggle removed

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

  # Actually execute the work when no duplicate exists
  defp execute_work_for_ticket(socket, ticket_id, ticket_details, coding_pref, claude_model, opencode_model) do
    # Build the prompt from ticket details
    prompt = """
    Work on ticket #{ticket_id}.
    
    Ticket details:
    #{ticket_details || "No details available - use the ticket ID to look it up."}
    
    Please analyze this ticket and implement the required changes.
    """

    cond do
      # If OpenCode mode is selected
      coding_pref == :opencode ->
        # Start work in supervised task
        parent = self()
        Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
          result = OpenCodeClient.send_task(prompt, model: opencode_model)
          send(parent, {:work_result, result})
        end)
        
        socket = socket
        |> assign(work_in_progress: true, work_error: nil)
        |> put_flash(:info, "Starting work with OpenCode (#{opencode_model})...")
        {:noreply, socket}
      
      # Gemini mode - send prompt to running Gemini CLI
      coding_pref == :gemini ->
        # Ensure Gemini server is running
        if GeminiServer.running?() do
          case GeminiServer.send_prompt(prompt) do
            :ok ->
              socket = socket
              |> assign(work_in_progress: false, work_error: nil, show_work_modal: false)
              |> put_flash(:info, "Prompt sent to Gemini CLI for #{ticket_id}")
              {:noreply, socket}
            {:error, reason} ->
              socket = socket
              |> assign(work_in_progress: false, work_error: "Failed to send to Gemini: #{inspect(reason)}")
              {:noreply, socket}
          end
        else
          # Start Gemini server first, then send prompt
          case GeminiServer.start_server() do
            {:ok, _pid} ->
              # Wait a bit for server to initialize
              Process.sleep(2000)
              case GeminiServer.send_prompt(prompt) do
                :ok ->
                  socket = socket
                  |> assign(work_in_progress: false, work_error: nil, show_work_modal: false, gemini_server_status: GeminiServer.status())
                  |> put_flash(:info, "Started Gemini and sent prompt for #{ticket_id}")
                  {:noreply, socket}
                {:error, reason} ->
                  socket = socket
                  |> assign(work_in_progress: false, work_error: "Gemini started but failed to send: #{inspect(reason)}", gemini_server_status: GeminiServer.status())
                  {:noreply, socket}
              end
            {:error, reason} ->
              socket = socket
              |> assign(work_in_progress: false, work_error: "Failed to start Gemini: #{inspect(reason)}")
              {:noreply, socket}
          end
        end
      
      # Claude mode - send to OpenClaw to spawn a sub-agent
      true ->
        alias DashboardPhoenix.OpenClawClient
        
        # Start work in supervised task
        parent = self()
        Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
          result = OpenClawClient.work_on_ticket(ticket_id, ticket_details, model: claude_model)
          send(parent, {:work_result, result})
        end)
        
        socket = socket
        |> assign(work_in_progress: true, work_error: nil, show_work_modal: false)
        |> put_flash(:info, "Sending work request to OpenClaw (#{claude_model})...")
        {:noreply, socket}
    end
  end

  # Push current panel state to JS for localStorage persistence
  defp push_panel_state(socket) do
    panels = %{
      "config" => socket.assigns.config_collapsed,
      "linear" => socket.assigns.linear_collapsed,
      "prs" => socket.assigns.prs_collapsed,
      "branches" => socket.assigns.branches_collapsed,
      "opencode" => socket.assigns.opencode_collapsed,
      "gemini" => socket.assigns.gemini_collapsed,
      "coding_agents" => socket.assigns.coding_agents_collapsed,
      "dave" => socket.assigns.dave_collapsed,
      "subagents" => socket.assigns.subagents_collapsed,
      "live_progress" => socket.assigns.live_progress_collapsed,
      "agent_activity" => socket.assigns.agent_activity_collapsed,
      "system_processes" => socket.assigns.system_processes_collapsed,
      "process_relationships" => socket.assigns.process_relationships_collapsed,
      "chat" => socket.assigns.chat_collapsed
    }
    push_event(socket, "save_panel_state", %{panels: panels})
  end

  # Push current model selections to JS for localStorage persistence
  defp push_model_selections(socket) do
    models = %{
      "claude_model" => socket.assigns.claude_model,
      "opencode_model" => socket.assigns.opencode_model
    }
    push_event(socket, "save_model_selections", %{models: models})
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
    session_key = Map.get(session, :session_key)
    cond do
      session_key && String.contains?(session_key, "main:main") -> :openclaw
      session_key && String.contains?(session_key, "subagent") -> :openclaw
      true -> :openclaw
    end
  end

  defp parse_event_time(ts) when is_integer(ts), do: DateTime.from_unix!(ts, :millisecond)
  defp parse_event_time(_), do: DateTime.utc_now()

  # Build map of ticket_id -> work session info from OpenCode and sub-agent sessions
  # Parses ticket IDs (like COR-123, FRE-456) from session titles and labels
  defp build_tickets_in_progress(opencode_sessions, agent_sessions) do
    ticket_regex = ~r/([A-Z]{2,5}-\d+)/i
    
    # Build from OpenCode sessions (look at title)
    opencode_work = opencode_sessions
    |> Enum.filter(fn session -> 
      # Only include active/running sessions
      session.status in ["active", "idle"]
    end)
    |> Enum.flat_map(fn session ->
      title = session.title || ""
      case Regex.scan(ticket_regex, title) do
        [] -> []
        matches -> 
          Enum.map(matches, fn [_, ticket_id] -> 
            {String.upcase(ticket_id), %{
              type: :opencode,
              slug: session.slug,
              session_id: session.id,
              status: session.status,
              title: session.title
            }}
          end)
      end
    end)
    
    # Build from sub-agent sessions (look at label and task_summary)
    subagent_work = agent_sessions
    |> Enum.filter(fn session -> 
      # Only include running/idle sessions (not completed)
      session.status in ["running", "idle"]
    end)
    |> Enum.flat_map(fn session ->
      label = Map.get(session, :label) || ""
      task = Map.get(session, :task_summary) || ""
      text_to_search = "#{label} #{task}"
      
      case Regex.scan(ticket_regex, text_to_search) do
        [] -> []
        matches -> 
          Enum.map(matches, fn [_, ticket_id] -> 
            {String.upcase(ticket_id), %{
              type: :subagent,
              label: label,
              session_id: session.id,
              status: session.status,
              task_summary: Map.get(session, :task_summary)
            }}
          end)
      end
    end)
    
    # Combine - OpenCode takes precedence if both are working on same ticket
    Map.new(subagent_work ++ opencode_work)
  end

  # Build graph data for relationship visualization
  defp build_graph_data(sessions, coding_agents, processes, opencode_sessions, gemini_status) do
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

  # Find an OpenCode session that matches the coding agent's working directory
  defp find_opencode_session(agent, opencode_sessions) when is_list(opencode_sessions) do
    agent_dir = agent.working_dir
    
    Enum.find(opencode_sessions, fn session ->
      session_dir = session.directory
      # Match if directories are the same
      agent_dir && session_dir && normalize_path(agent_dir) == normalize_path(session_dir)
    end)
  end
  defp find_opencode_session(_, _), do: nil

  defp normalize_path(nil), do: nil
  defp normalize_path(path), do: Path.expand(path)

  # Truncate title with ellipsis if too long
  defp truncate_title(nil), do: nil
  defp truncate_title(title) when byte_size(title) > 50 do
    String.slice(title, 0, 47) <> "..."
  end
  defp truncate_title(title), do: title

  # Linear-related helpers moved to LinearComponent

  defp opencode_status_badge("active"), do: "px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 text-[10px] animate-pulse"
  defp opencode_status_badge("subagent"), do: "px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-400 text-[10px]"
  defp opencode_status_badge("idle"), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]"
  defp opencode_status_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  # Coding agent badge helpers
  defp coding_agent_badge_class(:opencode), do: "bg-blue-500/20 text-blue-400"
  defp coding_agent_badge_class(:claude), do: "bg-purple-500/20 text-purple-400"
  defp coding_agent_badge_class(:gemini), do: "bg-green-500/20 text-green-400"
  defp coding_agent_badge_class(_), do: "bg-base-content/10 text-base-content/60"

  defp coding_agent_badge_text(:opencode), do: "💻 OpenCode"
  defp coding_agent_badge_text(:claude), do: "🤖 Claude"
  defp coding_agent_badge_text(:gemini), do: "✨ Gemini"
  defp coding_agent_badge_text(_), do: "❓ Unknown"

  defp coding_agent_button_class(:opencode), do: "bg-blue-500/20 text-blue-400"
  defp coding_agent_button_class(:claude), do: "bg-purple-500/20 text-purple-400"
  defp coding_agent_button_class(:gemini), do: "bg-green-500/20 text-green-400"
  defp coding_agent_button_class(_), do: "bg-base-content/10 text-base-content/60"

  defp coding_agent_icon(:opencode), do: "💻"
  defp coding_agent_icon(:claude), do: "🤖"
  defp coding_agent_icon(:gemini), do: "✨"
  defp coding_agent_icon(_), do: "❓"

  defp coding_agent_name(:opencode), do: "OpenCode"
  defp coding_agent_name(:claude), do: "Claude"
  defp coding_agent_name(:gemini), do: "Gemini"
  defp coding_agent_name(_), do: "Unknown"

  # Sub-agent type helpers - parse model string to determine agent type
  defp agent_type_from_model(model) when is_binary(model) do
    cond do
      String.contains?(model, "opus") -> {:claude, "Opus", "🤖"}
      String.contains?(model, "sonnet") -> {:claude, "Sonnet", "🤖"}
      String.contains?(model, "claude") -> {:claude, "Claude", "🤖"}
      String.contains?(model, "gemini") -> {:gemini, "Gemini", "✨"}
      String.contains?(model, "opencode") -> {:opencode, "OpenCode", "💻"}
      String.contains?(model, "gpt") -> {:openai, "GPT", "🧠"}
      true -> {:unknown, model, "⚡"}
    end
  end
  defp agent_type_from_model(_), do: {:unknown, "Unknown", "⚡"}

  defp agent_type_badge_class(:claude), do: "bg-purple-500/20 text-purple-400"
  defp agent_type_badge_class(:gemini), do: "bg-green-500/20 text-green-400"
  defp agent_type_badge_class(:opencode), do: "bg-blue-500/20 text-blue-400"
  defp agent_type_badge_class(:openai), do: "bg-emerald-500/20 text-emerald-400"
  defp agent_type_badge_class(_), do: "bg-base-content/10 text-base-content/60"

  # Get start timestamp from session for live duration
  defp session_start_timestamp(%{updated_at: updated_at, runtime: runtime}) when is_binary(runtime) do
    # Parse runtime to get approximate start time
    # Runtime format: "Xm Ys" or "Xh Ym" or "Xs"
    ms = parse_runtime_to_ms(runtime)
    if ms > 0 do
      updated_at - ms + (System.system_time(:millisecond) - updated_at)
    else
      updated_at
    end
  end
  defp session_start_timestamp(%{updated_at: updated_at}), do: updated_at - 60_000  # Default to 1 min ago
  defp session_start_timestamp(_), do: System.system_time(:millisecond)

  defp parse_runtime_to_ms(runtime) when is_binary(runtime) do
    cond do
      String.contains?(runtime, "h") ->
        case Regex.run(~r/(\d+)h\s*(\d+)m/, runtime) do
          [_, hours, mins] -> 
            (String.to_integer(hours) * 3_600_000) + (String.to_integer(mins) * 60_000)
          _ -> 0
        end
      String.contains?(runtime, "m") ->
        case Regex.run(~r/(\d+)m\s*(\d+)?s?/, runtime) do
          [_, mins, secs] -> 
            (String.to_integer(mins) * 60_000) + (String.to_integer(secs || "0") * 1_000)
          [_, mins] ->
            String.to_integer(mins) * 60_000
          _ -> 0
        end
      String.contains?(runtime, "s") ->
        case Regex.run(~r/(\d+)s/, runtime) do
          [_, secs] -> String.to_integer(secs) * 1_000
          _ -> 0
        end
      true -> 0
    end
  end
  defp parse_runtime_to_ms(_), do: 0

  # PR CI status badges
  defp pr_ci_badge(:success), do: "px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 text-[10px]"
  defp pr_ci_badge(:failure), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-[10px]"
  defp pr_ci_badge(:pending), do: "px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-[10px] animate-pulse"
  defp pr_ci_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  defp pr_ci_icon(:success), do: "✓"
  defp pr_ci_icon(:failure), do: "✗"
  defp pr_ci_icon(:pending), do: "○"
  defp pr_ci_icon(_), do: "?"

  # PR review status badges
  defp pr_review_badge(:approved), do: "px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 text-[10px]"
  defp pr_review_badge(:changes_requested), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-[10px]"
  defp pr_review_badge(:commented), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]"
  defp pr_review_badge(:pending), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"
  defp pr_review_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  defp pr_review_text(:approved), do: "Approved"
  defp pr_review_text(:changes_requested), do: "Changes"
  defp pr_review_text(:commented), do: "Comments"
  defp pr_review_text(:pending), do: "Pending"
  defp pr_review_text(_), do: "—"

  # Format PR creation time
  defp format_pr_time(nil), do: ""
  defp format_pr_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)
    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end
  defp format_pr_time(_), do: ""

  # Format branch time (same as PR time)
  defp format_branch_time(nil), do: ""
  defp format_branch_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)
    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end
  defp format_branch_time(_), do: ""

  # PR state persistence - stores which tickets have PRs created
  @pr_state_file Path.expand("~/.openclaw/systematic-pr-state.json")

  defp load_pr_state do
    case File.read(@pr_state_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"pr_created" => tickets}} when is_list(tickets) ->
            MapSet.new(tickets)
          _ ->
            MapSet.new()
        end
      {:error, _} ->
        MapSet.new()
    end
  end

  defp save_pr_state(pr_created) do
    content = Jason.encode!(%{"pr_created" => MapSet.to_list(pr_created)})
    File.mkdir_p!(Path.dirname(@pr_state_file))
    File.write!(@pr_state_file, content)
  end

  # Linear filter button styling moved to LinearComponent

  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex flex-col" id="panel-state-container" phx-hook="PanelState">
      <!-- Compact Header -->
      <div class="glass-panel rounded-lg px-4 py-2 flex items-center justify-between mb-3">
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
            <svg class="sun-icon w-4 h-4 text-yellow-400" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z" />
            </svg>
            <svg class="moon-icon w-4 h-4 text-indigo-400" style="display: none;" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z" />
            </svg>
          </button>
        </div>
        
        <!-- Compact Stats -->
        <div class="flex items-center space-x-6 text-xs font-mono">
          <div class="flex items-center space-x-2">
            <span class="text-base-content/50">Agents:</span>
            <span class="text-success font-bold"><%= length(@agent_sessions) %></span>
          </div>
          <div class="flex items-center space-x-2">
            <span class="text-base-content/50">Events:</span>
            <span class="text-primary font-bold"><%= length(@agent_progress) %></span>
          </div>
          <%= if @coding_agent_pref == :opencode do %>
            <div class="flex items-center space-x-2">
              <span class="text-base-content/50">ACP:</span>
              <%= if @opencode_server_status.running do %>
                <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
              <% else %>
                <span class="w-2 h-2 rounded-full bg-base-content/30"></span>
              <% end %>
            </div>
          <% end %>
          <div class="flex items-center space-x-1">
            <span class={"px-2 py-0.5 rounded text-[10px] " <> coding_agent_badge_class(@coding_agent_pref)}>
              <%= coding_agent_badge_text(@coding_agent_pref) %>
            </span>
          </div>
        </div>
      </div>

      <!-- Main Two-Column Layout -->
      <div class="flex-1 flex flex-col lg:flex-row gap-3 min-h-0">
        
        <!-- LEFT: Removed chat panel - use OpenClaw Control UI at https://balgownie.tail1b57dd.ts.net:8443/ -->

        <!-- Main Panels (full width, chat removed) -->
        <div class="w-full flex flex-col gap-3 overflow-y-auto">
          
          <!-- Compact Usage Stats -->
          <div class="glass-panel rounded-lg p-3">
            <div class="flex items-center justify-between mb-2">
              <span class="text-[10px] font-mono text-accent uppercase tracking-wider">📊 Usage</span>
              <button phx-click="refresh_stats" class="text-[10px] text-base-content/40 hover:text-accent">↻</button>
            </div>
            <div class="grid grid-cols-2 gap-3 text-xs font-mono">
              <div>
                <div class="text-base-content/50 mb-1">OpenCode</div>
                <div class="flex items-center space-x-2">
                  <span class="text-white font-bold"><%= @usage_stats.opencode[:sessions] || 0 %></span>
                  <span class="text-base-content/40">sess</span>
                  <span class="text-success"><%= @usage_stats.opencode[:total_cost] || "$0" %></span>
                </div>
              </div>
              <div>
                <div class="text-base-content/50 mb-1">Claude</div>
                <div class="flex items-center space-x-2">
                  <span class="text-white font-bold"><%= @usage_stats.claude[:sessions] || 0 %></span>
                  <span class="text-base-content/40">sess</span>
                  <span class="text-success"><%= @usage_stats.claude[:cost] || "$0" %></span>
                </div>
              </div>
            </div>
          </div>

          <!-- Linear Tickets Panel (LiveComponent) -->
          <.live_component
            module={LinearComponent}
            id="linear-tickets"
            linear_tickets={@linear_tickets}
            linear_counts={@linear_counts}
            linear_loading={@linear_loading}
            linear_error={@linear_error}
            linear_collapsed={@linear_collapsed}
            linear_status_filter={@linear_status_filter}
            tickets_in_progress={@tickets_in_progress}
          />

          <!-- GitHub Pull Requests Panel -->
          <div class="glass-panel rounded-lg overflow-hidden">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="prs"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@prs_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-accent uppercase tracking-wider">🔀 Pull Requests</span>
                <%= if @github_prs_loading do %>
                  <span class="throbber-small"></span>
                <% else %>
                  <span class="text-[10px] font-mono text-base-content/50"><%= length(@github_prs) %></span>
                <% end %>
              </div>
              <button phx-click="refresh_prs" class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">↻</button>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@prs_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
              <div class="px-3 pb-3">
                <!-- PR List -->
                <div class="space-y-2 max-h-[350px] overflow-y-auto">
                  <%= if @github_prs_loading do %>
                    <div class="flex items-center justify-center py-4 space-x-2">
                      <span class="throbber-small"></span>
                      <span class="text-xs text-base-content/50 font-mono">Loading PRs...</span>
                    </div>
                  <% else %>
                    <%= if @github_prs_error do %>
                      <div class="text-xs text-error/70 py-2 px-2"><%= @github_prs_error %></div>
                    <% end %>
                    <%= if @github_prs == [] do %>
                      <div class="text-xs text-base-content/50 py-4 text-center font-mono">No open PRs</div>
                    <% end %>
                    <%= for pr <- @github_prs do %>
                      <div class="px-2 py-2 rounded hover:bg-white/5 text-xs font-mono border border-white/5">
                        <!-- PR Title and Number -->
                        <div class="flex items-start justify-between mb-1">
                          <div class="flex-1 min-w-0">
                            <a href={pr.url} target="_blank" class="text-white hover:text-accent flex items-center space-x-1">
                              <span class="text-accent font-bold">#<%= pr.number %></span>
                              <span class="truncate"><%= pr.title %></span>
                            </a>
                          </div>
                          <!-- Super Review Button -->
                          <button
                            phx-click="request_pr_super_review"
                            phx-value-url={pr.url}
                            phx-value-number={pr.number}
                            phx-value-repo={pr.repo}
                            class="ml-2 px-2 py-0.5 rounded bg-purple-500/20 text-purple-400 hover:bg-purple-500/40 text-[10px] whitespace-nowrap"
                            title="Request Super Review"
                          >
                            🔍 Review
                          </button>
                        </div>
                        
                        <!-- Author and Branch -->
                        <div class="flex items-center space-x-2 text-[10px] text-base-content/50 mb-1.5">
                          <span>by <span class="text-base-content/70"><%= pr.author %></span></span>
                          <span>•</span>
                          <span class="truncate text-blue-400" title={pr.branch}><%= pr.branch %></span>
                          <span>•</span>
                          <span><%= format_pr_time(pr.created_at) %></span>
                        </div>
                        
                        <!-- Status Row: CI, Review, and Tickets -->
                        <div class="flex items-center space-x-2 flex-wrap gap-1">
                          <!-- CI Status -->
                          <span class={pr_ci_badge(pr.ci_status)} title="CI Status">
                            <%= pr_ci_icon(pr.ci_status) %> CI
                          </span>
                          
                          <!-- Conflict Badge -->
                          <%= if pr.has_conflicts do %>
                            <span class="px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-[10px]" title="Has merge conflicts">
                              ⚠️ Conflict
                            </span>
                          <% end %>
                          
                          <!-- Fix Button (for CI failures or conflicts) -->
                          <%= if pr.ci_status == :failure or pr.has_conflicts do %>
                            <button
                              phx-click="fix_pr_issues"
                              phx-value-url={pr.url}
                              phx-value-number={pr.number}
                              phx-value-repo={pr.repo}
                              phx-value-branch={pr.branch}
                              phx-value-has-conflicts={pr.has_conflicts}
                              phx-value-ci-failing={pr.ci_status == :failure}
                              class="px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 hover:bg-red-500/40 text-[10px]"
                              title="Send to coding agent to fix issues"
                            >
                              🔧 Fix
                            </button>
                          <% end %>
                          
                          <!-- Review Status -->
                          <span class={pr_review_badge(pr.review_status)} title="Review Status">
                            <%= pr_review_text(pr.review_status) %>
                          </span>
                          
                          <!-- Associated Tickets -->
                          <%= for ticket_id <- pr.ticket_ids do %>
                            <a 
                              href={PRMonitor.build_ticket_url(ticket_id)} 
                              target="_blank"
                              class="px-1.5 py-0.5 rounded bg-orange-500/20 text-orange-400 hover:bg-orange-500/40 text-[10px]"
                              title="View in Linear"
                            >
                              <%= ticket_id %>
                            </a>
                          <% end %>
                        </div>
                      </div>
                    <% end %>
                  <% end %>
                </div>
                
                <!-- Last Updated -->
                <%= if @github_prs_last_updated do %>
                  <div class="text-[9px] text-base-content/30 mt-2 text-right font-mono">
                    Updated <%= format_pr_time(@github_prs_last_updated) %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Unmerged Branches Panel -->
          <div class="glass-panel rounded-lg overflow-hidden">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="branches"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@branches_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-accent uppercase tracking-wider">🌿 Unmerged Branches</span>
                <%= if @branches_loading do %>
                  <span class="throbber-small"></span>
                <% else %>
                  <span class="text-[10px] font-mono text-base-content/50"><%= length(@unmerged_branches) %></span>
                <% end %>
              </div>
              <button phx-click="refresh_branches" class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">↻</button>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@branches_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
              <div class="px-3 pb-3">
                <!-- Branch List -->
                <div class="space-y-2 max-h-[350px] overflow-y-auto">
                  <%= if @branches_loading do %>
                    <div class="flex items-center justify-center py-4 space-x-2">
                      <span class="throbber-small"></span>
                      <span class="text-xs text-base-content/50 font-mono">Loading branches...</span>
                    </div>
                  <% else %>
                    <%= if @branches_error do %>
                      <div class="text-xs text-error/70 py-2 px-2"><%= @branches_error %></div>
                    <% end %>
                    <%= if @unmerged_branches == [] do %>
                      <div class="text-xs text-base-content/50 py-4 text-center font-mono">No unmerged branches</div>
                    <% end %>
                    <%= for branch <- @unmerged_branches do %>
                      <div class="px-2 py-2 rounded hover:bg-white/5 text-xs font-mono border border-white/5">
                        <!-- Branch Name and Actions -->
                        <div class="flex items-start justify-between mb-1">
                          <div class="flex items-center space-x-2 min-w-0">
                            <%= if branch.has_worktree do %>
                              <span class="text-green-400" title={"Worktree: #{branch.worktree_path}"}>🌲</span>
                            <% else %>
                              <span class="text-base-content/30">🔀</span>
                            <% end %>
                            <span class="text-white truncate" title={branch.name}><%= branch.name %></span>
                            <span class="px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]">
                              +<%= branch.commits_ahead %>
                            </span>
                          </div>
                          
                          <!-- Action Buttons -->
                          <div class="flex items-center space-x-1 ml-2">
                            <%= if @branch_merge_pending == branch.name do %>
                              <!-- Merge Confirmation -->
                              <span class="text-[10px] text-warning mr-1">Merge?</span>
                              <button
                                phx-click="execute_merge_branch"
                                phx-value-name={branch.name}
                                class="px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 hover:bg-green-500/40 text-[10px]"
                              >
                                ✓
                              </button>
                              <button
                                phx-click="cancel_merge_branch"
                                class="px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 hover:bg-base-content/20 text-[10px]"
                              >
                                ✗
                              </button>
                            <% else %>
                              <%= if @branch_delete_pending == branch.name do %>
                                <!-- Delete Confirmation -->
                                <span class="text-[10px] text-error mr-1">Delete?</span>
                                <button
                                  phx-click="execute_delete_branch"
                                  phx-value-name={branch.name}
                                  class="px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 hover:bg-red-500/40 text-[10px]"
                                >
                                  ✓
                                </button>
                                <button
                                  phx-click="cancel_delete_branch"
                                  class="px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 hover:bg-base-content/20 text-[10px]"
                                >
                                  ✗
                                </button>
                              <% else %>
                                <!-- Normal Buttons -->
                                <button
                                  phx-click="confirm_merge_branch"
                                  phx-value-name={branch.name}
                                  class="px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 hover:bg-green-500/40 text-[10px]"
                                  title="Merge to main"
                                >
                                  ⤵ Merge
                                </button>
                                <button
                                  phx-click="confirm_delete_branch"
                                  phx-value-name={branch.name}
                                  class="px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 hover:bg-red-500/40 text-[10px]"
                                  title="Delete branch"
                                >
                                  🗑
                                </button>
                              <% end %>
                            <% end %>
                          </div>
                        </div>
                        
                        <!-- Last Commit Info -->
                        <div class="flex items-center space-x-2 text-[10px] text-base-content/50">
                          <%= if branch.last_commit_message do %>
                            <span class="truncate flex-1" title={branch.last_commit_message}><%= branch.last_commit_message %></span>
                            <span>•</span>
                          <% end %>
                          <%= if branch.last_commit_author do %>
                            <span class="text-base-content/40"><%= branch.last_commit_author %></span>
                            <span>•</span>
                          <% end %>
                          <%= if branch.last_commit_date do %>
                            <span><%= format_branch_time(branch.last_commit_date) %></span>
                          <% end %>
                        </div>
                        
                        <!-- Worktree Path if applicable -->
                        <%= if branch.has_worktree do %>
                          <div class="text-[10px] text-green-400/60 mt-1 truncate" title={branch.worktree_path}>
                            📁 <%= branch.worktree_path %>
                          </div>
                        <% end %>
                      </div>
                    <% end %>
                  <% end %>
                </div>
                
                <!-- Last Updated -->
                <%= if @branches_last_updated do %>
                  <div class="text-[9px] text-base-content/30 mt-2 text-right font-mono">
                    Updated <%= format_branch_time(@branches_last_updated) %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <!-- OpenCode Sessions Panel -->
          <div class="glass-panel rounded-lg overflow-hidden">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="opencode"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@opencode_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-accent uppercase tracking-wider">💻 OpenCode</span>
                <span class="text-[10px] font-mono text-base-content/50"><%= length(@opencode_sessions) %></span>
              </div>
              <button phx-click="refresh_opencode_sessions" class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">↻</button>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@opencode_collapsed, do: "max-h-0", else: "max-h-[300px]")}>
              <div class="px-3 pb-3 space-y-1 max-h-[250px] overflow-y-auto">
                <%= if not @opencode_server_status.running do %>
                  <div class="text-center py-2">
                    <div class="text-[10px] text-base-content/40 mb-1">Server not running</div>
                    <button phx-click="start_opencode_server" class="text-[10px] px-2 py-1 rounded bg-success/20 text-success hover:bg-success/40">
                      Start
                    </button>
                  </div>
                <% else %>
                  <%= for session <- @opencode_sessions do %>
                    <div class="flex items-center space-x-2 px-2 py-1.5 rounded hover:bg-white/5 text-xs font-mono">
                      <span class={opencode_status_badge(session.status)}><%= session.status %></span>
                      <span class="text-white truncate flex-1" title={session.title}><%= session.slug %></span>
                      <%= if session.file_changes.files > 0 do %>
                        <span class="text-green-400 text-[10px]">+<%= session.file_changes.additions %></span>
                        <span class="text-red-400 text-[10px]">-<%= session.file_changes.deletions %></span>
                      <% end %>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Gemini CLI Panel -->
          <div class="glass-panel rounded-lg overflow-hidden">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="gemini"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@gemini_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-accent uppercase tracking-wider">✨ Gemini CLI</span>
                <%= if @gemini_server_status.running do %>
                  <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
                <% end %>
              </div>
              <%= if @gemini_server_status.running do %>
                <button phx-click="clear_gemini_output" class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">Clear</button>
              <% end %>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@gemini_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
              <div class="px-3 pb-3">
                <%= if not @gemini_server_status.running do %>
                  <div class="text-center py-4">
                    <div class="text-[10px] text-base-content/40 mb-2">Gemini CLI not running</div>
                    <button phx-click="start_gemini_server" class="text-xs px-3 py-1.5 rounded bg-green-500/20 text-green-400 hover:bg-green-500/40">
                      ✨ Start Gemini
                    </button>
                  </div>
                <% else %>
                  <!-- Status -->
                  <div class="flex items-center justify-between mb-2 text-[10px] font-mono">
                    <div class="flex items-center space-x-2">
                      <span class="text-base-content/50">Status:</span>
                      <%= if @gemini_server_status[:busy] do %>
                        <span class="text-warning animate-pulse">Running...</span>
                      <% else %>
                        <span class="text-green-400">Ready</span>
                      <% end %>
                      <span class="text-base-content/30">|</span>
                      <span class="text-base-content/50">Dir:</span>
                      <span class="text-blue-400 truncate max-w-[150px]" title={@gemini_server_status.cwd}><%= @gemini_server_status.cwd %></span>
                    </div>
                    <button phx-click="stop_gemini_server" class="px-2 py-0.5 rounded bg-error/20 text-error hover:bg-error/40 text-[10px]">
                      Stop
                    </button>
                  </div>
                  
                  <!-- Output -->
                  <div class="bg-black/40 rounded-lg p-2 mb-2 max-h-[200px] overflow-y-auto font-mono text-[10px] text-base-content/70" id="gemini-output" phx-hook="ScrollBottom">
                    <%= if @gemini_output == "" do %>
                      <span class="text-base-content/40 italic">Waiting for output...</span>
                    <% else %>
                      <pre class="whitespace-pre-wrap"><%= @gemini_output %></pre>
                    <% end %>
                  </div>
                  
                  <!-- Prompt Input -->
                  <form phx-submit="send_gemini_prompt" class="flex items-center space-x-2">
                    <input
                      type="text"
                      name="prompt"
                      placeholder="Send a prompt to Gemini..."
                      class="flex-1 bg-black/30 border border-white/10 rounded px-3 py-1.5 text-xs font-mono text-white placeholder-base-content/40 focus:outline-none focus:border-green-500/50"
                      autocomplete="off"
                    />
                    <button
                      type="submit"
                      class="px-3 py-1.5 rounded bg-green-500/20 text-green-400 hover:bg-green-500/40 text-xs font-mono"
                    >
                      Send
                    </button>
                  </form>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Dave Panel (Main Agent) -->
          <% main_agent_session = Enum.find(@agent_sessions, fn s -> Map.get(s, :session_key) == "agent:main:main" end) %>
          <%= if main_agent_session do %>
            <div class="glass-panel rounded-lg overflow-hidden border-2 border-purple-500/30" id="dave">
              <div 
                class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-purple-500/10 transition-colors bg-purple-500/5"
                phx-click="toggle_panel"
                phx-value-panel="dave"
              >
                <div class="flex items-center space-x-2">
                  <span class={"text-xs transition-transform duration-200 " <> if(@dave_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                  <span class="text-xs font-mono text-purple-400 uppercase tracking-wider">🐙 Dave</span>
                  <span class={"px-1.5 py-0.5 rounded text-[10px] " <> status_badge(main_agent_session.status)}>
                    <%= main_agent_session.status %>
                  </span>
                </div>
                <div class="flex items-center space-x-2">
                  <% {_type, model_name, model_icon} = agent_type_from_model(Map.get(main_agent_session, :model)) %>
                  <span class="px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-400 text-[10px]" title={Map.get(main_agent_session, :model)}>
                    <%= model_icon %> <%= model_name %>
                  </span>
                </div>
              </div>
              
              <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@dave_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
                <div class="px-3 pb-3">
                  <% current_action = Map.get(main_agent_session, :current_action) %>
                  <% recent_actions = Map.get(main_agent_session, :recent_actions, []) %>
                  
                  <!-- Current Activity -->
                  <div class="py-2">
                    <%= if main_agent_session.status == "running" do %>
                      <%= if current_action do %>
                        <div class="flex items-center space-x-2 mb-2">
                          <span class="throbber-small"></span>
                          <span class="text-[10px] text-purple-400/70">Current:</span>
                          <span class="text-purple-300 text-xs font-mono truncate animate-pulse" title={current_action}>
                            <%= current_action %>
                          </span>
                        </div>
                      <% else %>
                        <div class="flex items-center space-x-2 mb-2">
                          <span class="throbber-small"></span>
                          <span class="text-xs text-purple-400/60 italic">Working...</span>
                        </div>
                      <% end %>
                    <% else %>
                      <div class="flex items-center space-x-2 mb-2">
                        <span class="text-purple-400">○</span>
                        <span class="text-xs text-purple-400/60">Idle</span>
                      </div>
                    <% end %>
                    
                    <!-- Recent Actions -->
                    <%= if recent_actions != [] do %>
                      <div class="text-[10px] text-base-content/40 space-y-0.5 max-h-[100px] overflow-y-auto">
                        <%= for action <- Enum.take(recent_actions, -5) do %>
                          <div class="truncate" title={action}>✓ <%= action %></div>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                  
                  <!-- Stats Footer -->
                  <div class="pt-2 border-t border-purple-500/20 flex items-center justify-between text-[10px] font-mono">
                    <div class="flex items-center space-x-3 text-base-content/50">
                      <span>↓ <%= format_tokens(Map.get(main_agent_session, :tokens_in, 0)) %></span>
                      <span>↑ <%= format_tokens(Map.get(main_agent_session, :tokens_out, 0)) %></span>
                    </div>
                    <%= if Map.get(main_agent_session, :cost, 0) > 0 do %>
                      <span class="text-success/60">$<%= Float.round(main_agent_session.cost, 4) %></span>
                    <% end %>
                    <%= if Map.get(main_agent_session, :runtime) do %>
                      <span class="text-purple-400/60"><%= main_agent_session.runtime %></span>
                    <% end %>
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <!-- Sub-Agents Panel (Enhanced) -->
          <% sub_agent_sessions = Enum.reject(@agent_sessions, fn s -> Map.get(s, :session_key) == "agent:main:main" end) %>
          <div class="glass-panel rounded-lg overflow-hidden" id="subagents">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="subagents"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@subagents_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-accent uppercase tracking-wider">🤖 Sub-Agents</span>
                <span class="text-[10px] font-mono text-base-content/50"><%= length(sub_agent_sessions) %></span>
                <% running_count = Enum.count(sub_agent_sessions, fn s -> s.status == "running" end) %>
                <%= if running_count > 0 do %>
                  <span class="px-1.5 py-0.5 rounded bg-warning/20 text-warning text-[10px] animate-pulse">
                    <%= running_count %> active
                  </span>
                <% end %>
              </div>
              <% completed_count = Enum.count(sub_agent_sessions, fn s -> s.status == "completed" && !MapSet.member?(@dismissed_sessions, s.id) end) %>
              <%= if completed_count > 0 do %>
                <button phx-click="clear_completed" class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">
                  Clear <%= completed_count %>
                </button>
              <% end %>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@subagents_collapsed, do: "max-h-0", else: "max-h-[500px]")}>
              <div class="px-3 pb-3 space-y-2 max-h-[450px] overflow-y-auto">
                <% visible_sessions = sub_agent_sessions
                  |> Enum.reject(fn s -> MapSet.member?(@dismissed_sessions, s.id) end)
                  |> Enum.reject(fn s -> !@show_completed && s.status == "completed" end) %>
                <%= if visible_sessions == [] do %>
                  <div class="text-xs text-base-content/40 py-4 text-center font-mono">No active sub-agents</div>
                <% end %>
                <%= for session <- visible_sessions do %>
                  <% status = Map.get(session, :status, "unknown") %>
                  <% {agent_type, agent_name, agent_icon} = agent_type_from_model(Map.get(session, :model)) %>
                  <% task = Map.get(session, :task_summary) %>
                  <% current_action = Map.get(session, :current_action) %>
                  <% recent_actions = Map.get(session, :recent_actions, []) %>
                  <% start_time = session_start_timestamp(session) %>
                  
                  <div class={"rounded-lg border text-xs font-mono " <> 
                    if(status == "running", 
                      do: "bg-warning/5 border-warning/30", 
                      else: if(status == "completed", do: "bg-success/5 border-success/20", else: "bg-white/5 border-white/10"))}>
                    
                    <!-- Header Row: Status, Label, Agent Type, Duration -->
                    <div class="flex items-center justify-between px-3 py-2 border-b border-white/5">
                      <div class="flex items-center space-x-2 min-w-0 flex-1">
                        <%= if status == "running" do %>
                          <span class="throbber-small flex-shrink-0"></span>
                        <% else %>
                          <span class={"flex-shrink-0 " <> if(status == "completed", do: "text-success", else: "text-info")}>
                            <%= if status == "completed", do: "✓", else: "○" %>
                          </span>
                        <% end %>
                        <span class="text-white font-medium truncate" title={Map.get(session, :label) || Map.get(session, :id)}>
                          <%= Map.get(session, :label) || String.slice(Map.get(session, :id, ""), 0, 8) %>
                        </span>
                      </div>
                      
                      <div class="flex items-center space-x-2 flex-shrink-0">
                        <!-- Agent Type Badge -->
                        <span class={"px-1.5 py-0.5 rounded text-[10px] " <> agent_type_badge_class(agent_type)} title={Map.get(session, :model)}>
                          <%= agent_icon %> <%= agent_name %>
                        </span>
                        
                        <!-- Live Duration (for running) or Static (for completed) -->
                        <%= if status == "running" do %>
                          <span 
                            class="px-1.5 py-0.5 rounded bg-warning/20 text-warning text-[10px] tabular-nums"
                            id={"duration-#{session.id}"}
                            phx-hook="LiveDuration"
                            data-start-time={start_time}
                          >
                            <%= Map.get(session, :runtime) || "..." %>
                          </span>
                        <% else %>
                          <%= if Map.get(session, :runtime) do %>
                            <span class="px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px] tabular-nums">
                              <%= session.runtime %>
                            </span>
                          <% end %>
                        <% end %>
                        
                        <!-- Status Badge -->
                        <span class={status_badge(status)}><%= status %></span>
                      </div>
                    </div>
                    
                    <!-- Task Description -->
                    <%= if task do %>
                      <div class="px-3 py-2 border-b border-white/5">
                        <div class="text-[10px] text-base-content/50 mb-0.5">Task</div>
                        <div class="text-base-content/80 text-[11px] leading-relaxed" title={task}>
                          <%= task %>
                        </div>
                      </div>
                    <% end %>
                    
                    <!-- Live Work Status (for running agents) -->
                    <%= if status == "running" do %>
                      <div class="px-3 py-2">
                        <%= if current_action do %>
                          <div class="flex items-center space-x-2 mb-1">
                            <span class="text-[10px] text-warning/70">▶ Now:</span>
                            <span class="text-warning text-[11px] truncate animate-pulse" title={current_action}>
                              <%= current_action %>
                            </span>
                          </div>
                        <% end %>
                        
                        <%= if recent_actions != [] do %>
                          <div class="text-[10px] text-base-content/40 space-y-0.5">
                            <%= for action <- Enum.take(recent_actions, -3) do %>
                              <div class="truncate" title={action}>✓ <%= action %></div>
                            <% end %>
                          </div>
                        <% end %>
                        
                        <%= if current_action == nil && recent_actions == [] do %>
                          <div class="text-[10px] text-base-content/40 italic">Initializing...</div>
                        <% end %>
                      </div>
                    <% end %>
                    
                    <!-- Result snippet for completed agents -->
                    <%= if status == "completed" && Map.get(session, :result_snippet) do %>
                      <div class="px-3 py-2">
                        <div class="text-[10px] text-success/70 mb-0.5">Result</div>
                        <div class="text-base-content/70 text-[11px] truncate" title={session.result_snippet}>
                          <%= session.result_snippet %>
                        </div>
                      </div>
                    <% end %>
                    
                    <!-- Footer: Tokens & Cost (if available) -->
                    <%= if (Map.get(session, :tokens_in, 0) > 0 || Map.get(session, :tokens_out, 0) > 0) do %>
                      <div class="px-3 py-1.5 bg-black/20 flex items-center justify-between text-[10px] text-base-content/40">
                        <div class="flex items-center space-x-3">
                          <span>↓ <%= format_tokens(session.tokens_in) %></span>
                          <span>↑ <%= format_tokens(session.tokens_out) %></span>
                        </div>
                        <%= if Map.get(session, :cost, 0) > 0 do %>
                          <span class="text-success/60">$<%= Float.round(session.cost, 4) %></span>
                        <% end %>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Live Progress Panel -->
          <div class="glass-panel rounded-lg overflow-hidden flex-1 min-h-[200px]">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="live_progress"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@live_progress_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-accent uppercase tracking-wider">📡 Live Feed</span>
                <span class="text-[10px] font-mono text-base-content/50"><%= length(@agent_progress) %></span>
              </div>
              <button phx-click="clear_progress" class="text-[10px] text-base-content/40 hover:text-accent" onclick="event.stopPropagation()">Clear</button>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@live_progress_collapsed, do: "max-h-0", else: "max-h-[400px] flex-1")}>
              <div class="px-3 pb-3 h-full max-h-[350px] overflow-y-auto font-mono text-[10px]" id="progress-feed" phx-hook="ScrollBottom">
                <%= for event <- Enum.take(@agent_progress, -50) do %>
                  <div class="py-0.5 flex items-start space-x-1">
                    <span class="text-base-content/40 w-12 flex-shrink-0"><%= format_time(event.ts) %></span>
                    <span class={agent_color(event.agent) <> " w-20 flex-shrink-0 truncate"}><%= event.agent %></span>
                    <span class={action_color(event.action) <> " font-bold w-10 flex-shrink-0"}><%= event.action %></span>
                    <span class="text-base-content/70 truncate flex-1"><%= event.target %></span>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Bottom Panels Row (Less Important - Collapsed by Default) -->
      <div class="mt-3 space-y-2">
        
        <!-- Config Panel (Compact) -->
        <div class="glass-panel rounded-lg overflow-hidden">
          <div 
            class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
            phx-click="toggle_panel"
            phx-value-panel="config"
          >
            <div class="flex items-center space-x-2">
              <span class={"text-xs transition-transform duration-200 " <> if(@config_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
              <span class="text-xs font-mono text-base-content/60 uppercase tracking-wider">⚙️ Config</span>
            </div>
            <div class="flex items-center space-x-2 text-[10px] font-mono text-base-content/40">
              <span><%= if @coding_agent_pref == :opencode, do: "OpenCode + #{@opencode_model}", else: "Claude + #{String.replace(@claude_model, "anthropic/claude-", "")}" %></span>
            </div>
          </div>
          
          <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@config_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
            <div class="px-4 py-3 border-t border-white/5">
              <div class="grid grid-cols-1 md:grid-cols-4 gap-4">
                <!-- Coding Agent Toggle (3-way) -->
                <div>
                  <div class="text-[10px] font-mono text-base-content/50 mb-2">Coding Agent</div>
                  <div class="flex rounded-lg overflow-hidden border border-white/10">
                    <button 
                      phx-click="set_coding_agent"
                      phx-value-agent="opencode"
                      class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all " <> 
                        if(@coding_agent_pref == :opencode, 
                          do: "bg-blue-500/30 text-blue-400",
                          else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                        )}
                    >
                      <span>💻</span>
                      <span class="hidden sm:inline">OpenCode</span>
                    </button>
                    <button 
                      phx-click="set_coding_agent"
                      phx-value-agent="claude"
                      class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all border-x border-white/10 " <> 
                        if(@coding_agent_pref == :claude, 
                          do: "bg-purple-500/30 text-purple-400",
                          else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                        )}
                    >
                      <span>🤖</span>
                      <span class="hidden sm:inline">Claude</span>
                    </button>
                    <button 
                      phx-click="set_coding_agent"
                      phx-value-agent="gemini"
                      class={"flex-1 flex items-center justify-center space-x-1 px-2 py-2 text-xs font-mono transition-all " <> 
                        if(@coding_agent_pref == :gemini, 
                          do: "bg-green-500/30 text-green-400",
                          else: "bg-base-content/5 text-base-content/50 hover:bg-base-content/10"
                        )}
                    >
                      <span>✨</span>
                      <span class="hidden sm:inline">Gemini</span>
                    </button>
                  </div>
                </div>
                
                <!-- Claude Model -->
                <div>
                  <div class="text-[10px] font-mono text-base-content/50 mb-2">Claude Model</div>
                  <select 
                    phx-change="select_claude_model"
                    name="model"
                    class="w-full text-sm font-mono bg-purple-500/10 border border-purple-500/30 rounded-lg px-3 py-2 text-purple-400"
                  >
                    <option value="anthropic/claude-opus-4-5" selected={@claude_model == "anthropic/claude-opus-4-5"}>Opus</option>
                    <option value="anthropic/claude-sonnet-4-20250514" selected={@claude_model == "anthropic/claude-sonnet-4-20250514"}>Sonnet</option>
                  </select>
                </div>
                
                <!-- OpenCode Model -->
                <div>
                  <div class="text-[10px] font-mono text-base-content/50 mb-2">OpenCode Model</div>
                  <select 
                    phx-change="select_opencode_model"
                    name="model"
                    class="w-full text-sm font-mono bg-blue-500/10 border border-blue-500/30 rounded-lg px-3 py-2 text-blue-400"
                  >
                    <option value="gemini-3-pro" selected={@opencode_model == "gemini-3-pro"}>Gemini 3 Pro</option>
                    <option value="gemini-3-flash" selected={@opencode_model == "gemini-3-flash"}>Gemini 3 Flash</option>
                    <option value="gemini-2.5-pro" selected={@opencode_model == "gemini-2.5-pro"}>Gemini 2.5 Pro</option>
                  </select>
                </div>
              </div>
              
              <!-- Server Controls based on selected agent -->
              <div class="mt-3 pt-3 border-t border-white/5">
                <%= cond do %>
                  <% @coding_agent_pref == :opencode -> %>
                    <!-- OpenCode Server Controls -->
                    <div class="flex items-center justify-between">
                      <div class="flex items-center space-x-2 text-xs font-mono">
                        <span class="text-base-content/50">ACP Server:</span>
                        <%= if @opencode_server_status.running do %>
                          <span class="text-success">Running on :<%= @opencode_server_status.port %></span>
                        <% else %>
                          <span class="text-base-content/40">Stopped</span>
                        <% end %>
                      </div>
                      <%= if @opencode_server_status.running do %>
                        <button phx-click="stop_opencode_server" class="text-xs px-2 py-1 rounded bg-error/20 text-error hover:bg-error/40">Stop</button>
                      <% else %>
                        <button phx-click="start_opencode_server" class="text-xs px-2 py-1 rounded bg-success/20 text-success hover:bg-success/40">Start</button>
                      <% end %>
                    </div>
                  <% @coding_agent_pref == :gemini -> %>
                    <!-- Gemini CLI Controls -->
                    <div class="flex items-center justify-between">
                      <div class="flex items-center space-x-2 text-xs font-mono">
                        <span class="text-base-content/50">Gemini CLI:</span>
                        <%= if @gemini_server_status.running do %>
                          <%= if @gemini_server_status[:busy] do %>
                            <span class="text-warning animate-pulse">Running prompt...</span>
                          <% else %>
                            <span class="text-success">Ready</span>
                          <% end %>
                        <% else %>
                          <span class="text-base-content/40">Stopped</span>
                        <% end %>
                      </div>
                      <%= if @gemini_server_status.running do %>
                        <button phx-click="stop_gemini_server" class="text-xs px-2 py-1 rounded bg-error/20 text-error hover:bg-error/40">Stop</button>
                      <% else %>
                        <button phx-click="start_gemini_server" class="text-xs px-2 py-1 rounded bg-success/20 text-success hover:bg-success/40">Start</button>
                      <% end %>
                    </div>
                  <% true -> %>
                    <!-- Claude sub-agents don't need server controls -->
                    <div class="text-xs font-mono text-base-content/40">
                      Claude uses OpenClaw sub-agents (no server needed)
                    </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <!-- Coding Agents Panel -->
        <%= if @coding_agents != [] do %>
          <div class="glass-panel rounded-lg overflow-hidden">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="coding_agents"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@coding_agents_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-base-content/60 uppercase tracking-wider">💻 Coding Agents</span>
                <span class="text-[10px] font-mono text-base-content/50"><%= length(@coding_agents) %></span>
              </div>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@coding_agents_collapsed, do: "max-h-0", else: "max-h-[200px]")}>
              <div class="px-3 pb-3">
                <div class="grid grid-cols-2 lg:grid-cols-4 gap-2">
                  <%= for agent <- @coding_agents do %>
                    <div class={"px-2 py-1.5 rounded text-xs font-mono " <> if(agent.status == "running", do: "bg-warning/10", else: "bg-white/5")}>
                      <div class="flex items-center justify-between">
                        <span class="text-white font-bold"><%= agent.type %></span>
                        <button phx-click="kill_process" phx-value-pid={agent.pid} class="text-error/50 hover:text-error">✕</button>
                      </div>
                      <div class="text-[10px] text-base-content/50 mt-1">
                        CPU: <%= agent.cpu %>% | MEM: <%= agent.memory %>%
                      </div>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <!-- System & Relationships Row -->
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-2">
          <!-- System Processes -->
          <div class="glass-panel rounded-lg overflow-hidden">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="system_processes"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@system_processes_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-base-content/60 uppercase tracking-wider">⚙️ System</span>
                <span class="text-[10px] font-mono text-base-content/50"><%= length(@recent_processes) %></span>
              </div>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@system_processes_collapsed, do: "max-h-0", else: "max-h-[150px]")}>
              <div class="px-3 pb-3 grid grid-cols-2 gap-1">
                <%= for process <- Enum.take(@recent_processes, 4) do %>
                  <div class="px-2 py-1 rounded bg-white/5 text-[10px] font-mono">
                    <div class="text-white truncate"><%= process.name %></div>
                    <div class="text-base-content/50">CPU: <%= Map.get(process, :cpu_usage, "?") %> | MEM: <%= Map.get(process, :memory_usage, "?") %></div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>

          <!-- Process Relationships -->
          <div class="glass-panel rounded-lg overflow-hidden">
            <div 
              class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
              phx-click="toggle_panel"
              phx-value-panel="process_relationships"
            >
              <div class="flex items-center space-x-2">
                <span class={"text-xs transition-transform duration-200 " <> if(@process_relationships_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
                <span class="text-xs font-mono text-base-content/60 uppercase tracking-wider">🔗 Relationships</span>
              </div>
            </div>
            
            <div class={"transition-all duration-300 ease-in-out " <> if(@process_relationships_collapsed, do: "max-h-0 overflow-hidden", else: "")}>
              <div class="p-2">
                <div id="relationship-graph" phx-hook="RelationshipGraph" phx-update="ignore" class="w-full h-[180px]"></div>
              </div>
            </div>
          </div>
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
              <button phx-click="close_work_modal" class="text-base-content/60 hover:text-white text-xl">✕</button>
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
            
            <!-- Execute Work -->
            <div class="border-t border-white/10 pt-4">
              <div class="flex items-center justify-between mb-3">
                <div class="text-xs font-mono text-accent uppercase tracking-wider">Start Working</div>
                <div class={"text-[10px] font-mono px-2 py-1 rounded " <> coding_agent_badge_class(@coding_agent_pref)}>
                  Using: <%= coding_agent_badge_text(@coding_agent_pref) %>
                </div>
              </div>
              
              <%= if @work_error do %>
                <div class="bg-error/20 text-error rounded-lg p-3 text-sm font-mono mb-3"><%= @work_error %></div>
              <% end %>
              
              <div class="flex items-center space-x-3">
                <button
                  phx-click="execute_work"
                  disabled={@work_in_progress or @work_ticket_loading or @work_sent}
                  class={"flex-1 py-3 rounded-lg text-sm font-mono font-bold transition-all " <> 
                    cond do
                      @work_sent -> "bg-green-500/30 text-green-300"
                      @work_in_progress -> "bg-blue-500/30 text-blue-300 cursor-wait"
                      true -> "bg-accent/20 text-accent hover:bg-accent/40"
                    end}
                >
                  <%= cond do %>
                    <% @work_sent -> %>✓ Work Started
                    <% @work_in_progress -> %><span class="inline-block animate-spin mr-2">⟳</span> Starting...
                    <% true -> %>🚀 Execute Work
                  <% end %>
                </button>
                <a 
                  href={"https://linear.app/fresh-clinics/issue/#{@work_ticket_id}"} 
                  target="_blank"
                  class="px-4 py-3 rounded-lg bg-base-content/10 text-base-content/70 hover:bg-base-content/20 text-sm font-mono"
                >
                  Linear ↗
                </a>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
