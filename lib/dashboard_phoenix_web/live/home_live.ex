defmodule DashboardPhoenixWeb.HomeLive do
  @moduledoc """
  Main LiveView for the dashboard application.

  Orchestrates the entire dashboard interface including activity monitoring,
  system processes, agent management, and various operational panels.
  Handles real-time updates, user interactions, and coordination between
  multiple components for project management and system oversight.

  ## Architecture

  This LiveView follows a component-based architecture where most UI sections
  are handled by dedicated LiveComponents. HomeLive acts as the orchestrator:

  - Subscribes to PubSub topics and forwards updates to components
  - Manages cross-component state (work-in-progress tracking)
  - Handles modal dialogs and flash messages

  ## Extracted Modules

  Logic has been split into focused modules:

  - `SessionEnricher` - Extracts ticket/PR IDs from session data
  - `WorkProgressBuilder` - Builds work-in-progress tracking maps
  - `WorkExecutor` - Spawns work on different coding agents
  """
  use DashboardPhoenixWeb, :live_view

  # Extracted modules for cleaner separation
  alias DashboardPhoenixWeb.HomeLive.SessionEnricher
  alias DashboardPhoenixWeb.HomeLive.WorkProgressBuilder
  alias DashboardPhoenixWeb.HomeLive.WorkExecutor

  # Type definitions (detailed types in extracted modules)
  @typedoc "OpenCode server status"
  @type opencode_status :: %{running: boolean(), port: pos_integer() | nil, pid: String.t() | nil}

  # Component aliases
  alias DashboardPhoenixWeb.Live.Components.HeaderComponent
  alias DashboardPhoenixWeb.Live.Components.LinearComponent
  alias DashboardPhoenixWeb.Live.Components.ChainlinkComponent
  alias DashboardPhoenixWeb.Live.Components.PRsComponent
  alias DashboardPhoenixWeb.Live.Components.BranchesComponent
  alias DashboardPhoenixWeb.Live.Components.OpenCodeComponent
  alias DashboardPhoenixWeb.Live.Components.SubagentsComponent
  alias DashboardPhoenixWeb.Live.Components.GeminiComponent
  alias DashboardPhoenixWeb.Live.Components.ConfigComponent
  alias DashboardPhoenixWeb.Live.Components.DaveComponent
  alias DashboardPhoenixWeb.Live.Components.UnifiedActivityComponent
  alias DashboardPhoenixWeb.Live.Components.SystemProcessesComponent
  alias DashboardPhoenixWeb.Live.Components.UsageStatsComponent
  alias DashboardPhoenixWeb.Live.Components.WorkModalComponent
  # ActivityPanelComponent - now merged into UnifiedActivityComponent
  # Keep handler for backward compatibility
  alias DashboardPhoenixWeb.Live.Components.WorkPanelComponent
  alias DashboardPhoenixWeb.Live.Components.WorkRiverComponent
  alias DashboardPhoenixWeb.Live.Components.WorkContextModalComponent
  alias DashboardPhoenixWeb.Live.Components.TestRunnerComponent
  alias DashboardPhoenixWeb.Live.Components.TabsComponent
  alias DashboardPhoenix.ProcessMonitor
  alias DashboardPhoenix.ActivityLog
  alias DashboardPhoenix.SessionBridge
  alias DashboardPhoenix.StatsMonitor
  alias DashboardPhoenix.InputValidator
  alias DashboardPhoenix.ResourceTracker
  # AgentActivityMonitor subscription removed - activity is rebuilt from sessions+progress
  # which are already updated by SessionBridge subscription (Ticket #119)
  alias DashboardPhoenix.CodingAgentMonitor
  alias DashboardPhoenix.LinearMonitor
  alias DashboardPhoenix.ChainlinkMonitor
  alias DashboardPhoenix.ChainlinkWorkTracker
  alias DashboardPhoenix.PRMonitor
  alias DashboardPhoenix.PRVerification
  alias DashboardPhoenix.BranchMonitor
  alias DashboardPhoenix.AgentPreferences
  alias DashboardPhoenix.OpenCodeServer
  alias DashboardPhoenix.GeminiServer
  alias DashboardPhoenix.ClientFactory
  alias DashboardPhoenix.Status
  alias DashboardPhoenix.Paths
  alias DashboardPhoenix.FileUtils
  alias DashboardPhoenix.HealthCheck
  alias DashboardPhoenix.DashboardState
  alias DashboardPhoenix.TestRunner

  @doc "Mount callback - initializes socket assigns and subscribes to PubSub topics."
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(_params, _session, socket) do
    # Load persisted UI state (panels, dismissed sessions, models)
    persisted_state = DashboardState.get_state()
    # Initialize all assigns with empty/loading states first
    # This ensures the UI renders immediately with loading indicators
    socket =
      assign(socket,
        # Process data - loaded async
        process_stats: %{total: 0, running: 0, completed: 0, failed: 0},
        recent_processes: [],
        recent_processes_count: 0,
        processes_loading: true,
        # Session/progress data - loaded async
        agent_sessions: [],
        agent_progress: [],
        agent_sessions_count: 0,
        agent_progress_count: 0,
        sessions_loading: true,
        # Usage stats - loaded async (need default structure for component)
        usage_stats: %{opencode: %{}, claude: %{}},
        stats_loading: true,
        # Resource history - loaded async
        resource_history: [],
        # Agent activity - computed from sessions+progress
        agent_activity: [],
        # Coding agents - loaded async
        coding_agents: [],
        coding_agents_count: 0,
        coding_agents_loading: true,
        # Coding agent preference - loaded async
        # Default value
        coding_agent_pref: :opencode,
        # Agent distribution mode and round-robin state
        # "single" or "round_robin"
        agent_mode: "single",
        # Work registry - tracks all agent work with metadata
        work_registry_counts: %{claude: 0, opencode: 0, gemini: 0},
        work_registry_entries: [],
        # Last agent used in round_robin mode
        last_agent: "claude",
        # Graph data - computed after data loads
        graph_data: %{nodes: [], links: []},
        # UI state - load dismissed sessions from persisted state
        dismissed_sessions: MapSet.new(persisted_state.dismissed_sessions),
        show_main_entries: true,
        progress_filter: "all",
        show_completed: true,
        main_activity_count: 0,
        expanded_outputs: MapSet.new(),
        # Active tab for tabbed UI navigation (Ticket #127)
        active_tab: Map.get(persisted_state.panels, :active_tab, "work"),
        # Linear tickets - managed by LinearComponent (smart component)
        # Only need collapsed state for panel wrapper
        # Work in progress tracking - computed after data loads
        tickets_in_progress: %{},
        pr_created_tickets: MapSet.new(),
        prs_in_progress: %{},
        # Chainlink issues - managed by ChainlinkComponent (smart component)
        # Only need collapsed state for panel wrapper and work_in_progress for coordination
        chainlink_collapsed: persisted_state.panels.chainlink,
        chainlink_work_in_progress: WorkProgressBuilder.load_persisted_chainlink_work(),
        chainlink_error: nil,
        chainlink_loading: false,
        chainlink_issues: [],
        chainlink_issues_count: 0,
        # GitHub PRs - loaded async
        github_prs: [],
        github_prs_count: 0,
        github_prs_last_updated: nil,
        github_prs_error: nil,
        github_prs_loading: true,
        # Unmerged branches - loaded async
        unmerged_branches: [],
        unmerged_branches_count: 0,
        branches_worktrees: %{},
        branches_last_updated: nil,
        branches_error: nil,
        branches_loading: true,
        # Branch action states
        branch_merge_pending: nil,
        branch_delete_pending: nil,
        # PR fix action state
        pr_fix_pending: nil,
        # PR verifications - loaded async
        pr_verifications: %{},
        pr_verifications_loading: true,
        # Work modal state
        show_work_modal: false,
        work_ticket_id: nil,
        work_ticket_details: nil,
        work_ticket_loading: false,
        # OpenCode server state - loaded async
        opencode_server_status: %{running: false, port: nil, pid: nil},
        opencode_sessions: [],
        opencode_sessions_count: 0,
        opencode_loading: true,
        # Gemini server state - loaded async
        gemini_server_status: %{running: false, port: nil, pid: nil},
        gemini_output: "",
        gemini_loading: true,
        # Work in progress
        work_in_progress: false,
        work_sent: false,
        work_error: nil,
        # Model selections - load from persisted state
        claude_model: persisted_state.models.claude_model,
        opencode_model: persisted_state.models.opencode_model,
        # Health check status
        health_status: :unknown,
        health_last_check: nil,
        # Panel collapse states - load from persisted state
        config_collapsed: persisted_state.panels.config,
        linear_collapsed: persisted_state.panels.linear,
        prs_collapsed: persisted_state.panels.prs,
        branches_collapsed: persisted_state.panels.branches,
        opencode_collapsed: persisted_state.panels.opencode,
        gemini_collapsed: persisted_state.panels.gemini,
        coding_agents_collapsed: persisted_state.panels.coding_agents,
        subagents_collapsed: persisted_state.panels.subagents,
        dave_collapsed: persisted_state.panels.dave,
        live_progress_collapsed: persisted_state.panels.live_progress,
        agent_activity_collapsed: persisted_state.panels.agent_activity,
        system_processes_collapsed: persisted_state.panels.system_processes,
        process_relationships_collapsed: persisted_state.panels.process_relationships,
        chat_collapsed: persisted_state.panels.chat,
        test_runner_collapsed: persisted_state.panels.test_runner,
        # Activity panel state
        activity_events: [],
        activity_collapsed: persisted_state.panels.activity,
        # Work panel state
        work_panel_collapsed: persisted_state.panels.work_panel,
        # Work River state (holistic view)
        work_river_collapsed: Map.get(persisted_state.panels, :work_river, false),
        # Work Context Modal state
        show_work_context_modal: false,
        selected_work_item: nil,
        # Linear tickets for Work River (loaded via LinearMonitor)
        linear_tickets: [],
        # Test runner state
        test_running: false
      )

    # Initialize empty progress stream
    socket = stream(socket, :progress_events, [], dom_id: fn event -> "progress-#{event.ts}" end)

    if connected?(socket) do
      # Subscribe to all PubSub topics
      unless Application.get_env(:dashboard_phoenix, :disable_session_bridge, false) do
        SessionBridge.subscribe()
      end

      StatsMonitor.subscribe()
      ResourceTracker.subscribe()
      # AgentActivityMonitor.subscribe() removed - redundant, activity rebuilt from sessions+progress
      AgentPreferences.subscribe()
      LinearMonitor.subscribe()
      ChainlinkMonitor.subscribe()
      PRMonitor.subscribe()
      PRVerification.subscribe()
      BranchMonitor.subscribe()
      OpenCodeServer.subscribe()
      GeminiServer.subscribe()
      HealthCheck.subscribe()
      ActivityLog.subscribe()
      DashboardState.subscribe()

      # Schedule periodic updates (after initial data loads)
      Process.send_after(self(), :update_processes, 1_000)
      schedule_update_processes()
      schedule_refresh_opencode_sessions()

      # Trigger all async loads - UI renders immediately with loading states
      send(self(), :load_processes)
      send(self(), :load_sessions)
      send(self(), :load_stats)
      send(self(), :load_coding_agents)
      send(self(), :load_preferences)
      send(self(), :load_opencode_status)
      send(self(), :load_gemini_status)
      send(self(), :load_pr_verifications)
      send(self(), :load_pr_state)
      # Linear and Chainlink handled by smart components - just subscribe for forwarding
      # Also load for Work River
      send(self(), :load_linear_tickets)
      send(self(), :load_chainlink_issues)
      send(self(), :load_github_prs)
      send(self(), :load_branches)
      send(self(), :load_health_status)
      send(self(), :load_activity_events)
    end

    {:ok, socket}
  end

  # Handle health check updates (from PubSub)
  def handle_info({:health_update, health_state}, socket) do
    {:noreply,
     assign(socket,
       health_status: health_state.status,
       health_last_check: health_state.last_check
     )}
  end

  # Handle async health status loading (initial mount)
  def handle_info(:load_health_status, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        health_state = HealthCheck.get_status()
        send(parent, {:health_status_loaded, health_state})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load health status: #{inspect(e)}")
          send(parent, {:health_status_loaded, %{status: :unknown, last_check: nil}})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Health status load exited: #{inspect(reason)}")
          send(parent, {:health_status_loaded, %{status: :unknown, last_check: nil}})
      end
    end)

    {:noreply, socket}
  end

  # Handle health status loaded result
  def handle_info({:health_status_loaded, health_state}, socket) do
    {:noreply,
     assign(socket,
       health_status: health_state.status,
       health_last_check: health_state.last_check
     )}
  end

  # Handle activity log events (from PubSub)
  def handle_info({:activity_log_event, event}, socket) do
    # Add new event to the front of the list, keep last 20
    updated_events = [event | socket.assigns.activity_events] |> Enum.take(20)
    {:noreply, assign(socket, activity_events: updated_events)}
  end

  # Handle async activity events loading (initial mount)
  def handle_info(:load_activity_events, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        events = ActivityLog.get_events(20)
        send(parent, {:activity_events_loaded, events})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load activity events: #{inspect(e)}")
          send(parent, {:activity_events_loaded, []})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Activity events load exited: #{inspect(reason)}")
          send(parent, {:activity_events_loaded, []})
      end
    end)

    {:noreply, socket}
  end

  # Handle activity events loaded result
  def handle_info({:activity_events_loaded, events}, socket) do
    {:noreply, assign(socket, activity_events: events)}
  end

  # Handle activity panel component events
  def handle_info({:activity_panel_component, :toggle_panel}, socket) do
    socket = assign(socket, activity_collapsed: !socket.assigns.activity_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  # Handle unified activity component events
  def handle_info({:unified_activity_component, :toggle_panel}, socket) do
    socket = assign(socket, activity_collapsed: !socket.assigns.activity_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:unified_activity_component, :clear_progress}, socket) do
    # Delegate to the existing clear logic
    alias DashboardPhoenix.FileUtils
    alias DashboardPhoenix.Paths
    FileUtils.atomic_write(Paths.progress_file(), "")

    socket =
      socket
      |> assign(agent_progress: [], main_activity_count: 0, agent_progress_count: 0)
      |> stream(:progress_events, [], reset: true)

    {:noreply, socket}
  end

  def handle_info({:unified_activity_component, :toggle_output, ts_str}, socket) do
    ts = String.to_integer(ts_str)
    expanded = socket.assigns.expanded_outputs

    new_expanded =
      if MapSet.member?(expanded, ts) do
        MapSet.delete(expanded, ts)
      else
        MapSet.put(expanded, ts)
      end

    {:noreply, assign(socket, expanded_outputs: new_expanded)}
  end

  # Handle work panel component events
  def handle_info({:work_panel_component, :toggle_panel}, socket) do
    socket = assign(socket, work_panel_collapsed: !socket.assigns.work_panel_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  # Handle Work River component events
  def handle_info({:work_river_component, :toggle_panel}, socket) do
    socket = assign(socket, work_river_collapsed: !socket.assigns.work_river_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:work_river_component, :open_context, item}, socket) do
    socket = assign(socket, 
      show_work_context_modal: true,
      selected_work_item: item
    )
    {:noreply, socket}
  end

  def handle_info({:work_river_component, :start_work, {item_id, item_type}}, socket) do
    # Extract the actual identifier from the item_id (e.g., "linear-COR-123" -> "COR-123")
    actual_id = case item_type do
      "linear" -> String.replace_prefix(item_id, "linear-", "")
      "chainlink" -> 
        case String.replace_prefix(item_id, "chainlink-", "") |> Integer.parse() do
          {id, ""} -> id
          _ -> nil
        end
      _ -> item_id
    end
    
    case item_type do
      "linear" when is_binary(actual_id) ->
        # Trigger the existing work on ticket flow
        send(self(), {:linear_component, :work_on_ticket, actual_id})
      
      "chainlink" when is_integer(actual_id) ->
        # Trigger the existing chainlink work flow
        send(self(), {:chainlink_component, :work_on_issue, actual_id})
      
      _ ->
        nil
    end
    
    {:noreply, socket}
  end

  # Handle TabsComponent events (Ticket #127 - tabbed UI navigation)
  def handle_info({:tabs_component, :switch_tab, tab_id}, socket) do
    socket = assign(socket, active_tab: tab_id)
    {:noreply, push_tab_state(socket)}
  end

  # Handle Work Context Modal events
  def handle_info({:work_context_modal, :close}, socket) do
    {:noreply, assign(socket, show_work_context_modal: false, selected_work_item: nil)}
  end

  def handle_info({:work_context_modal, :start_work, item}, socket) do
    # Close modal and trigger work start
    socket = assign(socket, show_work_context_modal: false, selected_work_item: nil)
    
    case item.type do
      :linear ->
        send(self(), {:linear_component, :work_on_ticket, item.identifier})
      
      :chainlink ->
        issue_id = item.source_data.id
        send(self(), {:chainlink_component, :work_on_issue, issue_id})
      
      _ -> nil
    end
    
    {:noreply, socket}
  end

  def handle_info({:work_context_modal, :create_pr, session}, socket) do
    socket = assign(socket, show_work_context_modal: false, selected_work_item: nil)
    
    pr_prompt = """
    The work looks complete. Please create a Pull Request with:
    1. A clear, descriptive title
    2. A detailed description explaining what was changed and why
    3. Any relevant context for reviewers

    Use `gh pr create` to create the PR.
    """
    
    # Determine the type of session and send appropriate message
    cond do
      Map.get(session, :slug) ->
        # OpenCode session
        ClientFactory.opencode_client().send_message(session.id, pr_prompt)
      
      true ->
        # Claude sub-agent - send via main session
        ClientFactory.openclaw_client().send_message(pr_prompt, channel: "webchat")
    end
    
    {:noreply, put_flash(socket, :info, "PR creation requested")}
  end

  def handle_info({:work_context_modal, :fix_issues, pr}, socket) do
    socket = assign(socket, show_work_context_modal: false, selected_work_item: nil)
    
    # Use existing fix_pr_issues flow
    params = %{
      "url" => pr.url,
      "number" => to_string(pr.number),
      "repo" => pr.repo,
      "branch" => pr.branch,
      "has-conflicts" => to_string(Map.get(pr, :has_conflicts, false)),
      "ci-failing" => to_string(Map.get(pr, :ci_status) == "failure")
    }
    
    send(self(), {:prs_component, :fix_pr_issues, params})
    {:noreply, socket}
  end

  def handle_info({:work_context_modal, :merge_pr, pr}, socket) do
    socket = assign(socket, show_work_context_modal: false, selected_work_item: nil)
    
    merge_prompt = """
    Please merge PR ##{pr.number} in #{pr.repo}.
    
    Use: `gh pr merge #{pr.number} --repo #{pr.repo} --squash --delete-branch`
    
    After merging, confirm the merge was successful.
    """
    
    case ClientFactory.openclaw_client().spawn_subagent(merge_prompt,
           name: "pr-merge-#{pr.number}",
           thinking: "low",
           post_mode: "summary"
         ) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Merge sub-agent spawned for PR ##{pr.number}")}
      
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn merge agent: #{inspect(reason)}")}
    end
  end

  # Handle live progress updates (with validation for proper test isolation)
  def handle_info({:progress, events}, socket) when is_list(events) do
    updated = (socket.assigns.agent_progress ++ events) |> Enum.take(-100)

    activity =
      DashboardPhoenixWeb.HomeLiveCache.get_agent_activity(socket.assigns.agent_sessions, updated)

    main_activity_count = Enum.count(updated, &(&1.agent == "main"))
    agent_progress_count = length(updated)

    # Insert new events into stream
    socket =
      Enum.reduce(events, socket, fn event, acc ->
        stream_insert(acc, :progress_events, event, dom_id: "progress-#{event.ts}")
      end)

    {:noreply,
     assign(socket,
       agent_progress: updated,
       agent_progress_count: agent_progress_count,
       agent_activity: activity,
       main_activity_count: main_activity_count
     )}
  end

  # Handle malformed progress data gracefully (test isolation)
  def handle_info({:progress, _invalid}, socket) do
    {:noreply, socket}
  end

  # Handle session updates (with validation for proper test isolation)
  def handle_info({:sessions, raw_sessions}, socket) when is_list(raw_sessions) do
    alias DashboardPhoenix.WorkRegistry

    # Enrich sessions with extracted ticket/PR data once (O(n) instead of O(n*m))
    sessions = SessionEnricher.enrich_agent_sessions(raw_sessions)

    activity =
      DashboardPhoenixWeb.HomeLiveCache.get_agent_activity(
        sessions,
        socket.assigns.agent_progress
      )

    tickets_in_progress = WorkProgressBuilder.build_tickets_in_progress(socket.assigns.opencode_sessions, sessions)
    prs_in_progress = WorkProgressBuilder.build_prs_in_progress(socket.assigns.opencode_sessions, sessions)

    chainlink_work_in_progress =
      WorkProgressBuilder.build_chainlink_work_in_progress(sessions, socket.assigns.chainlink_work_in_progress)

    agent_sessions_count = length(sessions)

    # Sync WorkRegistry with active sessions
    active_session_ids =
      sessions
      |> Enum.filter(fn s -> s.status in [Status.running(), Status.idle()] end)
      |> Enum.map(& &1.id)

    WorkRegistry.sync_with_sessions(active_session_ids)

    # Get work registry counts for display
    work_registry_counts = WorkRegistry.count_by_agent_type()
    work_registry_entries = WorkRegistry.running()

    {:noreply,
     assign(socket,
       agent_sessions: sessions,
       agent_sessions_count: agent_sessions_count,
       agent_activity: activity,
       tickets_in_progress: tickets_in_progress,
       prs_in_progress: prs_in_progress,
       chainlink_work_in_progress: chainlink_work_in_progress,
       work_registry_counts: work_registry_counts,
       work_registry_entries: work_registry_entries
     )}
  end

  # Handle malformed session data gracefully (test isolation)
  def handle_info({:sessions, _invalid}, socket) do
    {:noreply, socket}
  end

  # Handle stats updates
  def handle_info({:stats_updated, stats}, socket) do
    {:noreply, assign(socket, usage_stats: stats)}
  end

  # Handle resource tracker updates
  def handle_info({:resource_update, %{history: history}}, socket) do
    {:noreply, assign(socket, resource_history: history)}
  end

  # AgentActivityMonitor subscription removed (Ticket #119)
  # The {:agent_activity, _} handler was redundant - it ignored the incoming data
  # and rebuilt activity from sessions+progress, which are already updated by
  # the {:sessions, _} and {:progress, _} handlers from SessionBridge.

  # Handle agent preferences updates
  def handle_info({:preferences_updated, prefs}, socket) do
    {:noreply,
     assign(socket,
       coding_agent_pref: String.to_atom(prefs.coding_agent),
       agent_mode: prefs.agent_mode,
       last_agent: prefs.last_agent
     )}
  end

  # Handle dashboard state updates (from other browser tabs/sessions)
  def handle_info({:dashboard_state_updated, state}, socket) do
    {:noreply,
     assign(socket,
       dismissed_sessions: MapSet.new(state.dismissed_sessions),
       claude_model: state.models.claude_model,
       opencode_model: state.models.opencode_model,
       config_collapsed: state.panels.config,
       linear_collapsed: state.panels.linear,
       chainlink_collapsed: state.panels.chainlink,
       prs_collapsed: state.panels.prs,
       branches_collapsed: state.panels.branches,
       opencode_collapsed: state.panels.opencode,
       gemini_collapsed: state.panels.gemini,
       coding_agents_collapsed: state.panels.coding_agents,
       subagents_collapsed: state.panels.subagents,
       dave_collapsed: state.panels.dave,
       live_progress_collapsed: state.panels.live_progress,
       agent_activity_collapsed: state.panels.agent_activity,
       system_processes_collapsed: state.panels.system_processes,
       process_relationships_collapsed: state.panels.process_relationships,
       chat_collapsed: state.panels.chat,
       test_runner_collapsed: state.panels.test_runner,
       activity_collapsed: state.panels.activity,
       work_panel_collapsed: state.panels.work_panel,
       work_river_collapsed: Map.get(state.panels, :work_river, false),
       active_tab: Map.get(state.panels, :active_tab, "work")
     )}
  end

  # Handle LinearComponent messages (smart component - only cross-component concerns)
  def handle_info({:linear_component, :toggle_panel}, socket) do
    socket = assign(socket, linear_collapsed: !socket.assigns.linear_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:linear_component, :work_on_ticket, ticket_id}, socket) do
    # Show modal immediately with loading state
    socket =
      assign(socket,
        show_work_modal: true,
        work_ticket_id: ticket_id,
        work_ticket_details: nil,
        work_ticket_loading: true,
        work_sent: false,
        work_error: nil
      )

    # Fetch ticket details async
    send(self(), {:fetch_ticket_details, ticket_id})

    {:noreply, socket}
  end

  # Handle Linear ticket updates (from PubSub) - forward to smart component and store for Work River
  def handle_info({:linear_update, data}, socket) do
    send_update(LinearComponent, id: :linear, linear_data: data)
    # Also store tickets locally for Work River component
    tickets = Map.get(data, :tickets, [])
    {:noreply, assign(socket, linear_tickets: tickets)}
  end

  # Handle ChainlinkComponent messages
  def handle_info({:chainlink_component, :toggle_panel}, socket) do
    socket = assign(socket, chainlink_collapsed: !socket.assigns.chainlink_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  # Note: refresh now handled directly by ChainlinkComponent (smart component)

  def handle_info({:chainlink_component, :work_on_issue, issue_id}, socket) do
    # Find the issue details from the monitor (component manages the list now)
    %{issues: issues} = ChainlinkMonitor.get_issues()
    issue = Enum.find(issues, &(&1.id == issue_id))

    if issue do
      # Build work prompt
      prompt = """
      Work on Chainlink issue ##{issue_id}: #{issue.title}

      Priority: #{issue.priority}

      Please analyze this issue and implement the required changes.
      Use `chainlink show #{issue_id}` to get full details.
      """

      # Spawn a sub-agent to work on it

      # Use coding preference (Claude vs OpenCode) like Linear tickets
      coding_pref = socket.assigns.coding_agent_pref

      case coding_pref do
        :opencode ->
          # Spawn via OpenCode
          opencode_model = socket.assigns.opencode_model

          case ClientFactory.opencode_client().send_task(prompt, model: opencode_model) do
            {:ok, _result} ->
              work_info = %{
                label: "chainlink-#{issue_id}",
                agent_type: "opencode",
                model: opencode_model,
                started_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }

              ChainlinkWorkTracker.start_work(issue_id, work_info)

              chainlink_wip =
                Map.put(socket.assigns.chainlink_work_in_progress, issue_id, work_info)

              ActivityLog.log_event(:task_started, "Work started on Chainlink ##{issue_id}", %{
                issue_id: issue_id,
                title: issue.title,
                priority: issue.priority,
                agent: "opencode",
                model: opencode_model
              })

              socket =
                socket
                |> assign(chainlink_work_in_progress: chainlink_wip)
                |> put_flash(
                  :info,
                  "Started work on Chainlink ##{issue_id} with OpenCode (#{opencode_model})"
                )

              {:noreply, socket}

            {:error, reason} ->
              {:noreply,
               put_flash(socket, :error, "Failed to start OpenCode work: #{inspect(reason)}")}
          end

        :gemini ->
          # Spawn via Gemini CLI
          if GeminiServer.running?() do
            case GeminiServer.send_prompt(prompt) do
              :ok ->
                work_info = %{
                  label: "chainlink-#{issue_id}",
                  agent_type: "gemini",
                  model: "gemini-2.0-flash",
                  started_at: DateTime.utc_now() |> DateTime.to_iso8601()
                }

                ChainlinkWorkTracker.start_work(issue_id, work_info)

                chainlink_wip =
                  Map.put(socket.assigns.chainlink_work_in_progress, issue_id, work_info)

                ActivityLog.log_event(:task_started, "Work started on Chainlink ##{issue_id}", %{
                  issue_id: issue_id,
                  title: issue.title,
                  priority: issue.priority,
                  agent: "gemini",
                  model: "gemini-2.0-flash"
                })

                socket =
                  socket
                  |> assign(chainlink_work_in_progress: chainlink_wip)
                  |> put_flash(:info, "Started work on Chainlink ##{issue_id} with Gemini")

                {:noreply, socket}

              {:error, reason} ->
                {:noreply,
                 put_flash(socket, :error, "Failed to send to Gemini: #{inspect(reason)}")}
            end
          else
            {:noreply, put_flash(socket, :error, "Gemini server not running")}
          end

        _ ->
          # Default: spawn Claude sub-agent
          claude_model = socket.assigns.claude_model

          case ClientFactory.openclaw_client().spawn_subagent(prompt,
                 name: "chainlink-#{issue_id}",
                 thinking: "low",
                 post_mode: "summary",
                 model: claude_model
               ) do
            {:ok, result} ->
              job_id = Map.get(result, :job_id, "unknown")
              name = Map.get(result, :name, "chainlink-#{issue_id}")

              work_info = %{
                label: name,
                job_id: job_id,
                agent_type: "claude",
                model: claude_model,
                started_at: DateTime.utc_now() |> DateTime.to_iso8601()
              }

              ChainlinkWorkTracker.start_work(issue_id, work_info)

              chainlink_wip =
                Map.put(socket.assigns.chainlink_work_in_progress, issue_id, work_info)

              ActivityLog.log_event(:task_started, "Work started on Chainlink ##{issue_id}", %{
                issue_id: issue_id,
                title: issue.title,
                priority: issue.priority,
                agent: "claude",
                model: claude_model
              })

              socket =
                socket
                |> assign(chainlink_work_in_progress: chainlink_wip)
                |> put_flash(
                  :info,
                  "Started work on Chainlink ##{issue_id} with Claude (#{claude_model})"
                )

              {:noreply, socket}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to start work: #{inspect(reason)}")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "Issue ##{issue_id} not found")}
    end
  end

  # Handle Chainlink issue updates (from PubSub) - forward to smart component and store for Work River
  def handle_info({:chainlink_update, data} = msg, socket) do
    ChainlinkComponent.handle_pubsub(msg, socket)
    # Also update local state for Work River component
    issues = Map.get(data, :issues, socket.assigns.chainlink_issues)
    {:noreply, assign(socket, chainlink_issues: issues)}
  end

  # PRsComponent handlers
  def handle_info({:prs_component, :toggle_panel}, socket) do
    socket = assign(socket, prs_collapsed: !socket.assigns.prs_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:prs_component, :refresh}, socket) do
    PRMonitor.refresh()
    {:noreply, socket}
  end

  def handle_info({:prs_component, :fix_pr_issues, params}, socket) do
    %{"url" => pr_url, "number" => pr_number, "repo" => repo, "branch" => branch} = params
    pr_number_int = String.to_integer(pr_number)
    has_conflicts = params["has-conflicts"] == "true"
    ci_failing = params["ci-failing"] == "true"

    # Set pending state immediately for instant UI feedback
    socket = assign(socket, pr_fix_pending: pr_number_int)

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
    1. First, check out the branch: `cd #{Paths.core_platform_repo()} && git fetch origin && git checkout #{branch}`
    #{if has_conflicts, do: "2. Resolve merge conflicts: `git fetch origin main && git merge origin/main` - fix any conflicts, then commit", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "3", else: "2"}. Get CI failure details: `gh pr checks #{pr_number} --repo #{repo}`", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "4", else: "3"}. Review the failing checks and fix the issues (tests, linting, type errors, etc.)", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "5", else: "4"}. Run tests locally to verify: `mix test`", else: ""}
    - Commit and push the fixes

    Focus on fixing the issues, not refactoring unrelated code.
    """

    case ClientFactory.openclaw_client().spawn_subagent(fix_prompt,
           name: "pr-fix-#{pr_number}",
           thinking: "low",
           post_mode: "summary"
         ) do
      {:ok, %{job_id: job_id}} ->
        socket =
          socket
          |> assign(pr_fix_pending: nil)
          |> put_flash(
            :info,
            "Fix sub-agent spawned for PR ##{pr_number} (job: #{String.slice(job_id, 0, 8)}...)"
          )

        {:noreply, socket}

      {:ok, _} ->
        socket =
          socket
          |> assign(pr_fix_pending: nil)
          |> put_flash(:info, "Fix sub-agent spawned for PR ##{pr_number}")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(pr_fix_pending: nil)
          |> put_flash(:error, "Failed to spawn fix agent: #{inspect(reason)}")

        {:noreply, socket}
    end
  end

  def handle_info(
        {:prs_component, :verify_pr, %{"url" => pr_url, "number" => pr_number, "repo" => repo}},
        socket
      ) do
    PRVerification.mark_verified(pr_url, "manual",
      pr_number: String.to_integer(pr_number),
      repo: repo,
      status: "clean"
    )

    {:noreply, put_flash(socket, :info, "PR ##{pr_number} marked as verified")}
  end

  def handle_info({:prs_component, :clear_verification, %{"url" => pr_url}}, socket) do
    PRVerification.clear_verification(pr_url)
    {:noreply, socket}
  end

  def handle_info(
        {:prs_component, :super_review,
         %{"url" => pr_url, "number" => pr_number, "repo" => repo}},
        socket
      ) do
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

    case ClientFactory.openclaw_client().spawn_subagent(review_prompt,
           name: "pr-review-#{pr_number}",
           thinking: "medium",
           post_mode: "summary"
         ) do
      {:ok, %{job_id: job_id}} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Review sub-agent spawned for PR ##{pr_number} (job: #{String.slice(job_id, 0, 8)}...)"
         )}

      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Review sub-agent spawned for PR ##{pr_number}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn review agent: #{inspect(reason)}")}
    end
  end

  # BranchesComponent handlers
  def handle_info({:branches_component, :toggle_panel}, socket) do
    socket = assign(socket, branches_collapsed: !socket.assigns.branches_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:branches_component, :refresh}, socket) do
    BranchMonitor.refresh()
    {:noreply, socket}
  end

  def handle_info({:branches_component, :confirm_merge, branch_name}, socket) do
    {:noreply, assign(socket, branch_merge_pending: branch_name)}
  end

  def handle_info({:branches_component, :cancel_merge}, socket) do
    {:noreply, assign(socket, branch_merge_pending: nil)}
  end

  def handle_info({:branches_component, :execute_merge, branch_name}, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      result = BranchMonitor.merge_branch(branch_name)
      send(parent, {:branch_merge_result, branch_name, result})
    end)

    {:noreply, assign(socket, branch_merge_pending: nil)}
  end

  def handle_info({:branches_component, :confirm_delete, branch_name}, socket) do
    {:noreply, assign(socket, branch_delete_pending: branch_name)}
  end

  def handle_info({:branches_component, :cancel_delete}, socket) do
    {:noreply, assign(socket, branch_delete_pending: nil)}
  end

  def handle_info({:branches_component, :execute_delete, branch_name}, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      result = BranchMonitor.delete_branch(branch_name)
      send(parent, {:branch_delete_result, branch_name, result})
    end)

    {:noreply, assign(socket, branch_delete_pending: nil)}
  end

  # Handle SubagentsComponent messages
  def handle_info({:subagents_component, :toggle_panel}, socket) do
    socket = assign(socket, subagents_collapsed: !socket.assigns.subagents_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:subagents_component, :clear_completed}, socket) do
    # Get all completed session IDs and add them to dismissed
    completed_ids =
      socket.assigns.agent_sessions
      |> Enum.filter(fn s -> s.status == Status.completed() end)
      |> Enum.map(fn s -> s.id end)

    dismissed =
      Enum.reduce(completed_ids, socket.assigns.dismissed_sessions, fn id, acc ->
        MapSet.put(acc, id)
      end)

    # Persist to server (survives restarts)
    DashboardState.dismiss_sessions(completed_ids)

    {:noreply, assign(socket, dismissed_sessions: dismissed)}
  end

  # ============================================================================
  # ASYNC LOAD HANDLERS - All heavy data loading happens here, not in mount/3
  # This ensures the UI renders immediately with loading states
  # ============================================================================

  # Handle async process loading (initial mount)
  def handle_info(:load_processes, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        processes = ProcessMonitor.list_processes()
        send(parent, {:processes_loaded, processes})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load processes: #{inspect(e)}")
          send(parent, {:processes_loaded, []})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Processes load exited: #{inspect(reason)}")
          send(parent, {:processes_loaded, []})
      end
    end)

    {:noreply, socket}
  end

  # Handle processes loaded result
  def handle_info({:processes_loaded, processes}, socket) do
    {:noreply,
     assign(socket,
       process_stats: ProcessMonitor.get_stats(processes),
       recent_processes: processes,
       recent_processes_count: length(processes),
       processes_loading: false
     )}
  end

  # Handle async sessions/progress loading (initial mount)
  def handle_info(:load_sessions, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        if Application.get_env(:dashboard_phoenix, :disable_session_bridge, false) do
          send(parent, {:sessions_loaded, [], []})
        else
          raw_sessions = SessionBridge.get_sessions()
          progress = SessionBridge.get_progress()
          send(parent, {:sessions_loaded, raw_sessions, progress})
        end
      rescue
        e ->
          require Logger
          Logger.error("Failed to load sessions: #{inspect(e)}")
          send(parent, {:sessions_loaded, [], []})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Sessions load exited: #{inspect(reason)}")
          send(parent, {:sessions_loaded, [], []})
      end
    end)

    {:noreply, socket}
  end

  # Handle sessions/progress loaded result
  def handle_info({:sessions_loaded, raw_sessions, progress}, socket) do
    # Enrich sessions with extracted ticket/PR data once (O(n) instead of O(n*m))
    sessions = SessionEnricher.enrich_agent_sessions(raw_sessions)
    activity = DashboardPhoenixWeb.HomeLiveCache.get_agent_activity(sessions, progress)
    main_activity_count = Enum.count(progress, &(&1.agent == "main"))

    # Rebuild work-in-progress maps now that we have sessions
    tickets_in_progress = WorkProgressBuilder.build_tickets_in_progress(socket.assigns.opencode_sessions, sessions)
    prs_in_progress = WorkProgressBuilder.build_prs_in_progress(socket.assigns.opencode_sessions, sessions)

    chainlink_work_in_progress =
      WorkProgressBuilder.build_chainlink_work_in_progress(sessions, socket.assigns.chainlink_work_in_progress)

    # Rebuild graph data if coding agents are loaded
    graph_data =
      if socket.assigns.coding_agents_loading do
        socket.assigns.graph_data
      else
        DashboardPhoenixWeb.HomeLiveCache.get_graph_data(
          sessions,
          socket.assigns.coding_agents,
          socket.assigns.recent_processes,
          socket.assigns.opencode_sessions,
          socket.assigns.gemini_server_status
        )
      end

    # Initialize progress stream with recent events
    recent_progress = Enum.take(progress, -50)

    socket =
      stream(socket, :progress_events, recent_progress,
        reset: true,
        dom_id: fn event -> "progress-#{event.ts}" end
      )

    socket =
      socket
      |> assign(
        agent_sessions: sessions,
        agent_progress: progress,
        agent_sessions_count: length(sessions),
        agent_progress_count: length(progress),
        agent_activity: activity,
        main_activity_count: main_activity_count,
        tickets_in_progress: tickets_in_progress,
        prs_in_progress: prs_in_progress,
        chainlink_work_in_progress: chainlink_work_in_progress,
        graph_data: graph_data,
        sessions_loading: false
      )
      |> push_event("graph_update", graph_data)

    {:noreply, socket}
  end

  # Handle async stats loading (initial mount)
  def handle_info(:load_stats, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        stats = StatsMonitor.get_stats()
        resource_history = ResourceTracker.get_history()
        send(parent, {:stats_loaded, stats, resource_history})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load stats: #{inspect(e)}")
          send(parent, {:stats_loaded, %{}, []})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Stats load exited: #{inspect(reason)}")
          send(parent, {:stats_loaded, %{}, []})
      end
    end)

    {:noreply, socket}
  end

  # Handle stats loaded result
  def handle_info({:stats_loaded, stats, resource_history}, socket) do
    {:noreply,
     assign(socket,
       usage_stats: stats,
       resource_history: resource_history,
       stats_loading: false
     )}
  end

  # Handle async coding agents loading (initial mount)
  def handle_info(:load_coding_agents, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        agents = CodingAgentMonitor.list_agents()
        send(parent, {:coding_agents_loaded, agents})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load coding agents: #{inspect(e)}")
          send(parent, {:coding_agents_loaded, []})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Coding agents load exited: #{inspect(reason)}")
          send(parent, {:coding_agents_loaded, []})
      end
    end)

    {:noreply, socket}
  end

  # Handle coding agents loaded result
  def handle_info({:coding_agents_loaded, agents}, socket) do
    # Rebuild graph data if sessions are loaded
    graph_data =
      if socket.assigns.sessions_loading do
        socket.assigns.graph_data
      else
        DashboardPhoenixWeb.HomeLiveCache.get_graph_data(
          socket.assigns.agent_sessions,
          agents,
          socket.assigns.recent_processes,
          socket.assigns.opencode_sessions,
          socket.assigns.gemini_server_status
        )
      end

    socket =
      socket
      |> assign(
        coding_agents: agents,
        coding_agents_count: length(agents),
        coding_agents_loading: false,
        graph_data: graph_data
      )
      |> push_event("graph_update", graph_data)

    {:noreply, socket}
  end

  # Handle async preferences loading (initial mount)
  def handle_info(:load_preferences, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        prefs = AgentPreferences.get_preferences()
        send(parent, {:preferences_loaded, prefs})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load preferences: #{inspect(e)}")

          send(
            parent,
            {:preferences_loaded,
             %{coding_agent: "opencode", agent_mode: "single", last_agent: "claude"}}
          )
      catch
        :exit, reason ->
          require Logger
          Logger.error("Preferences load exited: #{inspect(reason)}")

          send(
            parent,
            {:preferences_loaded,
             %{coding_agent: "opencode", agent_mode: "single", last_agent: "claude"}}
          )
      end
    end)

    {:noreply, socket}
  end

  # Handle preferences loaded result
  def handle_info({:preferences_loaded, prefs}, socket) do
    {:noreply,
     assign(socket,
       coding_agent_pref: String.to_atom(prefs.coding_agent),
       agent_mode: prefs.agent_mode,
       last_agent: prefs.last_agent
     )}
  end

  # Handle async OpenCode status loading (initial mount)
  def handle_info(:load_opencode_status, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        status = OpenCodeServer.status()
        sessions = fetch_opencode_sessions(status)
        send(parent, {:opencode_status_loaded, status, sessions})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load OpenCode status: #{inspect(e)}")
          send(parent, {:opencode_status_loaded, %{running: false, port: nil, pid: nil}, []})
      catch
        :exit, reason ->
          require Logger
          Logger.error("OpenCode status load exited: #{inspect(reason)}")
          send(parent, {:opencode_status_loaded, %{running: false, port: nil, pid: nil}, []})
      end
    end)

    {:noreply, socket}
  end

  # Handle OpenCode status loaded result
  def handle_info({:opencode_status_loaded, status, sessions}, socket) do
    # Rebuild work-in-progress maps with OpenCode sessions
    tickets_in_progress = WorkProgressBuilder.build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
    prs_in_progress = WorkProgressBuilder.build_prs_in_progress(sessions, socket.assigns.agent_sessions)

    {:noreply,
     assign(socket,
       opencode_server_status: status,
       opencode_sessions: sessions,
       opencode_sessions_count: length(sessions),
       opencode_loading: false,
       tickets_in_progress: tickets_in_progress,
       prs_in_progress: prs_in_progress
     )}
  end

  # Handle async Gemini status loading (initial mount)
  def handle_info(:load_gemini_status, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        status = GeminiServer.status()
        send(parent, {:gemini_status_loaded, status})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load Gemini status: #{inspect(e)}")
          send(parent, {:gemini_status_loaded, %{running: false, port: nil, pid: nil}})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Gemini status load exited: #{inspect(reason)}")
          send(parent, {:gemini_status_loaded, %{running: false, port: nil, pid: nil}})
      end
    end)

    {:noreply, socket}
  end

  # Handle Gemini status loaded result
  def handle_info({:gemini_status_loaded, status}, socket) do
    {:noreply, assign(socket, gemini_server_status: status, gemini_loading: false)}
  end

  # Handle async PR verifications loading (initial mount)
  def handle_info(:load_pr_verifications, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        verifications = PRVerification.get_all_verifications()
        send(parent, {:pr_verifications_loaded, verifications})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load PR verifications: #{inspect(e)}")
          send(parent, {:pr_verifications_loaded, %{}})
      catch
        :exit, reason ->
          require Logger
          Logger.error("PR verifications load exited: #{inspect(reason)}")
          send(parent, {:pr_verifications_loaded, %{}})
      end
    end)

    {:noreply, socket}
  end

  # Handle PR verifications loaded result
  def handle_info({:pr_verifications_loaded, verifications}, socket) do
    {:noreply, assign(socket, pr_verifications: verifications, pr_verifications_loading: false)}
  end

  # Handle async PR state loading (initial mount)
  def handle_info(:load_pr_state, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        pr_created = load_pr_state()
        send(parent, {:pr_state_loaded, pr_created})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load PR state: #{inspect(e)}")
          send(parent, {:pr_state_loaded, MapSet.new()})
      catch
        :exit, reason ->
          require Logger
          Logger.error("PR state load exited: #{inspect(reason)}")
          send(parent, {:pr_state_loaded, MapSet.new()})
      end
    end)

    {:noreply, socket}
  end

  # Handle PR state loaded result
  def handle_info({:pr_state_loaded, pr_created}, socket) do
    {:noreply, assign(socket, pr_created_tickets: pr_created)}
  end

  # Linear and Chainlink loading now handled by smart components

  # Handle GitHub PR updates (from PubSub)
  def handle_info({:pr_update, data}, socket) do
    {:noreply,
     assign(socket,
       github_prs: data.prs,
       github_prs_count: length(data.prs),
       github_prs_last_updated: data.last_updated,
       github_prs_error: data.error,
       github_prs_loading: false
     )}
  end

  # Handle PR verification updates (from PubSub)
  def handle_info({:pr_verification_update, verifications}, socket) do
    {:noreply, assign(socket, pr_verifications: verifications)}
  end

  # Handle async Linear tickets loading (for Work River)
  def handle_info(:load_linear_tickets, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        %{tickets: tickets} = LinearMonitor.get_tickets()
        send(parent, {:linear_tickets_loaded, tickets})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load Linear tickets: #{inspect(e)}")
          send(parent, {:linear_tickets_loaded, []})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Linear tickets load exited: #{inspect(reason)}")
          send(parent, {:linear_tickets_loaded, []})
      end
    end)

    {:noreply, socket}
  end

  # Handle Linear tickets loaded result
  def handle_info({:linear_tickets_loaded, tickets}, socket) do
    {:noreply, assign(socket, linear_tickets: tickets)}
  end

  # Handle async Chainlink issues loading (for Work River)
  def handle_info(:load_chainlink_issues, socket) do
    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        %{issues: issues} = ChainlinkMonitor.get_issues()
        send(parent, {:chainlink_issues_loaded, issues})
      rescue
        e ->
          require Logger
          Logger.error("Failed to load Chainlink issues: #{inspect(e)}")
          send(parent, {:chainlink_issues_loaded, []})
      catch
        :exit, reason ->
          require Logger
          Logger.error("Chainlink issues load exited: #{inspect(reason)}")
          send(parent, {:chainlink_issues_loaded, []})
      end
    end)

    {:noreply, socket}
  end

  # Handle Chainlink issues loaded result
  def handle_info({:chainlink_issues_loaded, issues}, socket) do
    {:noreply, assign(socket, chainlink_issues: issues)}
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

          send(
            parent,
            {:github_prs_loaded,
             %{prs: [], last_updated: nil, error: "Load failed: #{inspect(e)}"}}
          )
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
    {:noreply,
     assign(socket,
       github_prs: data.prs,
       github_prs_count: length(data.prs),
       github_prs_last_updated: data.last_updated,
       github_prs_error: data.error,
       github_prs_loading: false
     )}
  end

  # Handle branch updates (from PubSub)
  def handle_info({:branch_update, data}, socket) do
    {:noreply,
     assign(socket,
       unmerged_branches: data.branches,
       unmerged_branches_count: length(data.branches),
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

          send(
            parent,
            {:branches_loaded,
             %{
               branches: [],
               worktrees: %{},
               last_updated: nil,
               error: "Load failed: #{inspect(e)}"
             }}
          )
      catch
        :exit, reason ->
          require Logger
          Logger.error("Branches load exited: #{inspect(reason)}")

          send(
            parent,
            {:branches_loaded,
             %{branches: [], worktrees: %{}, last_updated: nil, error: "Load timeout"}}
          )
      end
    end)

    {:noreply, socket}
  end

  # Handle branches loaded result
  def handle_info({:branches_loaded, data}, socket) do
    {:noreply,
     assign(socket,
       unmerged_branches: data.branches,
       unmerged_branches_count: length(data.branches),
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
        socket =
          socket
          |> assign(branch_merge_pending: nil)
          |> put_flash(:info, "Successfully merged #{branch_name} to main")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(branch_merge_pending: nil)
          |> put_flash(:error, "Merge failed: #{reason}")

        {:noreply, socket}
    end
  end

  # Handle branch delete result
  def handle_info({:branch_delete_result, branch_name, result}, socket) do
    case result do
      {:ok, _} ->
        socket =
          socket
          |> assign(branch_delete_pending: nil)
          |> put_flash(:info, "Successfully deleted #{branch_name}")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(branch_delete_pending: nil)
          |> put_flash(:error, "Delete failed: #{reason}")

        {:noreply, socket}
    end
  end

  # OpenCodeComponent handlers
  def handle_info({:opencode_component, :toggle_panel}, socket) do
    socket = assign(socket, opencode_collapsed: !socket.assigns.opencode_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:opencode_component, :refresh}, socket) do
    sessions = fetch_opencode_sessions(socket.assigns.opencode_server_status)
    tickets_in_progress = WorkProgressBuilder.build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
    prs_in_progress = WorkProgressBuilder.build_prs_in_progress(sessions, socket.assigns.agent_sessions)

    {:noreply,
     assign(socket,
       opencode_sessions: sessions,
       tickets_in_progress: tickets_in_progress,
       prs_in_progress: prs_in_progress
     )}
  end

  def handle_info({:opencode_component, :start_server}, socket) do
    case OpenCodeServer.start_server() do
      {:ok, port} ->
        socket =
          socket
          |> assign(opencode_server_status: OpenCodeServer.status())
          |> put_flash(:info, "OpenCode server started on port #{port}")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to start OpenCode server: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  def handle_info({:opencode_component, :stop_server}, socket) do
    OpenCodeServer.stop_server()

    socket =
      socket
      |> assign(opencode_server_status: OpenCodeServer.status())
      |> put_flash(:info, "OpenCode server stopped")

    {:noreply, socket}
  end

  def handle_info({:opencode_component, :close_session, session_id}, socket) do
    case ClientFactory.opencode_client().delete_session(session_id) do
      :ok ->
        sessions = fetch_opencode_sessions(socket.assigns.opencode_server_status)
        tickets_in_progress = WorkProgressBuilder.build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
        prs_in_progress = WorkProgressBuilder.build_prs_in_progress(sessions, socket.assigns.agent_sessions)

        socket =
          socket
          |> assign(
            opencode_sessions: sessions,
            tickets_in_progress: tickets_in_progress,
            prs_in_progress: prs_in_progress
          )
          |> put_flash(:info, "Session closed")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to close session: #{reason}")}
    end
  end

  def handle_info({:opencode_component, :request_pr, session_id}, socket) do
    prompt = """
    The work looks complete. Please create a Pull Request with:
    1. A clear, descriptive title
    2. A detailed description explaining what was changed and why
    3. Any relevant context for reviewers

    Use `gh pr create` to create the PR.
    """

    case ClientFactory.opencode_client().send_message(session_id, prompt) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "PR requested for session")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to request PR: #{reason}")}
    end
  end

  # Handle GeminiComponent messages
  def handle_info({:gemini_component, :toggle_panel}, socket) do
    socket = assign(socket, gemini_collapsed: !socket.assigns.gemini_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:gemini_component, :start_server}, socket) do
    DashboardPhoenix.GeminiServer.start_server()
    {:noreply, socket}
  end

  def handle_info({:gemini_component, :stop_server}, socket) do
    DashboardPhoenix.GeminiServer.stop_server()
    {:noreply, assign(socket, gemini_output: "")}
  end

  def handle_info({:gemini_component, :send_prompt, prompt}, socket) do
    case DashboardPhoenix.GeminiServer.send_prompt(prompt) do
      {:ok, _} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send prompt: #{reason}")}
    end
  end

  def handle_info({:gemini_component, :clear_output}, socket) do
    {:noreply, assign(socket, gemini_output: "")}
  end

  # Handle ConfigComponent messages
  def handle_info({:config_component, :toggle_panel}, socket) do
    socket = assign(socket, config_collapsed: !socket.assigns.config_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:config_component, :set_coding_agent, agent}, socket) do
    agent_atom = String.to_existing_atom(agent)
    AgentPreferences.set_coding_agent(agent_atom)
    {:noreply, assign(socket, coding_agent_pref: agent_atom)}
  end

  def handle_info({:config_component, :set_agent_mode, mode}, socket) do
    AgentPreferences.set_agent_mode(mode)
    {:noreply, assign(socket, agent_mode: mode)}
  end

  def handle_info({:config_component, :select_claude_model, model}, socket) do
    socket = assign(socket, claude_model: model)
    {:noreply, push_model_selections(socket)}
  end

  def handle_info({:config_component, :select_opencode_model, model}, socket) do
    socket = assign(socket, opencode_model: model)
    {:noreply, push_model_selections(socket)}
  end

  def handle_info({:config_component, :start_opencode_server}, socket) do
    # Get model and start server with it
    model = socket.assigns.opencode_model

    case OpenCodeServer.start_server(%{model: model}) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "OpenCode server starting with #{model}...")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start server: #{reason}")}
    end
  end

  def handle_info({:config_component, :stop_opencode_server}, socket) do
    OpenCodeServer.stop_server()
    {:noreply, socket}
  end

  def handle_info({:config_component, :start_gemini_server}, socket) do
    DashboardPhoenix.GeminiServer.start_server()
    {:noreply, socket}
  end

  def handle_info({:config_component, :stop_gemini_server}, socket) do
    DashboardPhoenix.GeminiServer.stop_server()
    {:noreply, assign(socket, gemini_output: "")}
  end

  # Handle DaveComponent messages
  def handle_info({:dave_component, :toggle_panel}, socket) do
    socket = assign(socket, dave_collapsed: !socket.assigns.dave_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  # Handle LiveProgressComponent messages
  def handle_info({:live_progress_component, :toggle_panel}, socket) do
    socket = assign(socket, live_progress_collapsed: !socket.assigns.live_progress_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  # Handle SystemProcessesComponent messages
  def handle_info({:system_processes_component, :toggle_panel, "coding_agents"}, socket) do
    socket = assign(socket, coding_agents_collapsed: !socket.assigns.coding_agents_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:system_processes_component, :toggle_panel, "system_processes"}, socket) do
    socket =
      assign(socket, system_processes_collapsed: !socket.assigns.system_processes_collapsed)

    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:system_processes_component, :toggle_panel, "process_relationships"}, socket) do
    socket =
      assign(socket,
        process_relationships_collapsed: !socket.assigns.process_relationships_collapsed
      )

    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:test_runner_component, :toggle_panel, "test_runner"}, socket) do
    socket = assign(socket, test_runner_collapsed: !socket.assigns.test_runner_collapsed)
    {:noreply, push_panel_state(socket)}
  end

  def handle_info({:test_runner_component, :run_tests, test_files}, socket) do
    Task.start(fn ->
      case TestRunner.run_tests(test_files) do
        {:ok, _output} ->
          send(self(), {:test_runner_complete, :success})

        {:error, _reason} ->
          send(self(), {:test_runner_complete, :error})
      end
    end)

    {:noreply, socket}
  end

  def handle_info({:test_runner_component, :run_test_pattern, pattern}, socket) do
    Task.start(fn ->
      case TestRunner.run_tests_for(pattern) do
        {:ok, _output} ->
          send(self(), {:test_runner_complete, :success})

        {:error, _reason} ->
          send(self(), {:test_runner_complete, :error})
      end
    end)

    {:noreply, socket}
  end

  def handle_info({:test_runner_complete, _result}, socket) do
    socket = assign(socket, test_running: false)
    {:noreply, socket}
  end

  def handle_info({:system_processes_component, :kill_process, pid}, socket) do
    case DashboardPhoenix.CodingAgentMonitor.kill_agent(pid) do
      :ok ->
        coding_agents = DashboardPhoenix.CodingAgentMonitor.list_agents()

        socket =
          socket
          |> assign(coding_agents: coding_agents, coding_agents_count: length(coding_agents))
          |> put_flash(:info, "Process #{pid} terminated")

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Failed to kill process: #{reason}")
        {:noreply, socket}
    end
  end

  # Handle UsageStatsComponent messages
  def handle_info({:usage_stats_component, :refresh_stats}, socket) do
    StatsMonitor.refresh()
    {:noreply, socket}
  end

  # Handle WorkModalComponent messages
  def handle_info({:work_modal_component, :close}, socket) do
    {:noreply,
     assign(socket,
       show_work_modal: false,
       work_ticket_id: nil,
       work_ticket_details: nil,
       work_ticket_loading: false,
       work_sent: false,
       work_error: nil
     )}
  end

  def handle_info(
        {:work_modal_component, :work_already_exists, {ticket_id, agent_type, work_info}},
        socket
      ) do
    socket =
      socket
      |> assign(show_work_modal: false)
      |> put_flash(
        :error,
        "Work already in progress for #{ticket_id} (#{agent_type}: #{work_info[:slug] || work_info[:label]})"
      )

    {:noreply, socket}
  end

  def handle_info(
        {:work_modal_component, :execute_work,
         {ticket_id, ticket_details, coding_pref, claude_model, opencode_model}},
        socket
      ) do
    # In round_robin mode, get next agent and update state
    {effective_pref, socket} =
      case socket.assigns.agent_mode do
        "round_robin" ->
          {:ok, next_agent} = AgentPreferences.next_agent()
          # Update socket with the new last_agent (inverse of what we got)
          new_last = if next_agent == :claude, do: "claude", else: "opencode"
          {next_agent, assign(socket, last_agent: new_last)}

        "single" ->
          {coding_pref, socket}
      end

    # Use WorkExecutor to spawn the work
    WorkExecutor.execute_linear_work(ticket_id, ticket_details,
      coding_pref: effective_pref,
      claude_model: claude_model,
      opencode_model: opencode_model,
      callback_pid: self()
    )

    agent_label =
      case effective_pref do
        :opencode -> "OpenCode (#{opencode_model})"
        :gemini -> "Gemini"
        _ -> "Claude (#{claude_model})"
      end

    socket =
      socket
      |> assign(work_in_progress: true, work_error: nil, show_work_modal: false)
      |> put_flash(:info, "Starting work with #{agent_label}...")

    {:noreply, socket}
  end

  def handle_info({:live_progress_component, :clear_progress}, socket) do
    # Use atomic write to prevent race conditions with readers
    alias DashboardPhoenix.FileUtils
    alias DashboardPhoenix.Paths
    FileUtils.atomic_write(Paths.progress_file(), "")
    # Reset the stream by re-initializing it with empty data
    socket =
      socket
      |> assign(agent_progress: [], main_activity_count: 0)
      |> stream(:progress_events, [], reset: true)

    {:noreply, socket}
  end

  def handle_info({:live_progress_component, :toggle_main_entries}, socket) do
    {:noreply, assign(socket, show_main_entries: !socket.assigns.show_main_entries)}
  end

  def handle_info({:live_progress_component, :set_progress_filter, filter}, socket) do
    {:noreply, assign(socket, progress_filter: filter)}
  end

  def handle_info({:live_progress_component, :toggle_output, ts_str}, socket) do
    ts = String.to_integer(ts_str)
    expanded = socket.assigns.expanded_outputs

    new_expanded =
      if MapSet.member?(expanded, ts) do
        MapSet.delete(expanded, ts)
      else
        MapSet.put(expanded, ts)
      end

    {:noreply, assign(socket, expanded_outputs: new_expanded)}
  end

  # Handle OpenCode server status updates
  def handle_info({:opencode_status, status}, socket) do
    sessions = fetch_opencode_sessions(status)
    tickets_in_progress = WorkProgressBuilder.build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
    prs_in_progress = WorkProgressBuilder.build_prs_in_progress(sessions, socket.assigns.agent_sessions)

    {:noreply,
     assign(socket,
       opencode_server_status: status,
       opencode_sessions: sessions,
       tickets_in_progress: tickets_in_progress,
       prs_in_progress: prs_in_progress
     )}
  end

  # Handle Gemini server status updates
  def handle_info({:gemini_status, status}, socket) do
    {:noreply, assign(socket, gemini_server_status: status)}
  end

  # Handle Gemini output updates
  def handle_info({:gemini_output, output}, socket) do
    # Append new output, keeping last 5000 chars
    new_output = socket.assigns.gemini_output <> output

    new_output =
      if String.length(new_output) > 5000 do
        String.slice(new_output, -5000..-1)
      else
        new_output
      end

    {:noreply, assign(socket, gemini_output: new_output)}
  end

  # Handle periodic OpenCode sessions refresh
  def handle_info(:refresh_opencode_sessions, socket) do
    result =
      if socket.assigns.opencode_server_status.running do
        sessions = fetch_opencode_sessions(socket.assigns.opencode_server_status)
        tickets_in_progress = WorkProgressBuilder.build_tickets_in_progress(sessions, socket.assigns.agent_sessions)
        prs_in_progress = WorkProgressBuilder.build_prs_in_progress(sessions, socket.assigns.agent_sessions)
        opencode_sessions_count = length(sessions)

        assign(socket,
          opencode_sessions: sessions,
          opencode_sessions_count: opencode_sessions_count,
          tickets_in_progress: tickets_in_progress,
          prs_in_progress: prs_in_progress
        )
      else
        socket
      end

    # Schedule next refresh after processing completes
    schedule_refresh_opencode_sessions()
    {:noreply, result}
  end

  # Handle async work result (from OpenCode or OpenClaw)
  def handle_info({:work_result, result}, socket) do
    case result do
      {:ok, %{session_id: session_id}} ->
        socket =
          socket
          |> assign(work_in_progress: false, work_sent: true, work_error: nil)
          |> put_flash(:info, "Task sent to OpenCode (session: #{session_id})")

        {:noreply, socket}

      {:ok, %{ticket_id: ticket_id}} ->
        socket =
          socket
          |> assign(work_in_progress: false, work_sent: true, work_error: nil)
          |> put_flash(:info, "Work request sent to OpenClaw for #{ticket_id}")

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> assign(
            work_in_progress: false,
            work_sent: false,
            work_error: "Failed: #{inspect(reason)}"
          )

        {:noreply, socket}
    end
  end

  # Handle chat result
  # Handle async ticket details fetch
  def handle_info({:fetch_ticket_details, ticket_id}, socket) do
    details =
      case LinearMonitor.get_ticket_details(ticket_id) do
        {:ok, output} -> output
        {:error, reason} -> "Error fetching details: #{reason}"
      end

    {:noreply,
     assign(socket,
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

    graph_data =
      DashboardPhoenixWeb.HomeLiveCache.get_graph_data(
        sessions,
        coding_agents,
        processes,
        opencode_sessions,
        gemini_status
      )

    # Pre-calculate counts
    recent_processes_count = length(processes)
    coding_agents_count = length(coding_agents)

    socket =
      socket
      |> assign(
        process_stats: ProcessMonitor.get_stats(processes),
        recent_processes: processes,
        recent_processes_count: recent_processes_count,
        coding_agents: coding_agents,
        coding_agents_count: coding_agents_count,
        graph_data: graph_data
      )
      |> push_event("graph_update", graph_data)

    # Schedule next update after processing completes
    schedule_update_processes()
    {:noreply, socket}
  end

  def handle_event("kill_agent", %{"id" => _id}, socket) do
    socket = put_flash(socket, :info, "Kill not implemented for sub-agents yet")
    {:noreply, socket}
  end

  def handle_event("toggle_show_completed", _, socket) do
    {:noreply, assign(socket, show_completed: !socket.assigns.show_completed)}
  end

  def handle_event("toggle_main_entries", _, socket) do
    {:noreply, assign(socket, show_main_entries: !socket.assigns.show_main_entries)}
  end

  def handle_event("refresh_stats", _, socket) do
    StatsMonitor.refresh()
    {:noreply, socket}
  end

  def handle_event("toggle_panel", %{"panel" => panel}, socket) do
    case InputValidator.validate_panel_name(panel) do
      {:ok, validated_panel} ->
        # Skip panels now handled by SystemProcessesComponent
        case validated_panel do
          "coding_agents" ->
            {:noreply, socket}

          "system_processes" ->
            {:noreply, socket}

          "process_relationships" ->
            {:noreply, socket}

          _ ->
            try do
              key = String.to_existing_atom(validated_panel <> "_collapsed")
              socket = assign(socket, key, !Map.get(socket.assigns, key))
              {:noreply, push_panel_state(socket)}
            rescue
              ArgumentError ->
                socket = put_flash(socket, :error, "Unknown panel: #{validated_panel}")
                {:noreply, socket}
            end
        end

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid panel name: #{reason}")
        {:noreply, socket}
    end
  end

  # Restore panel state from localStorage via JS hook
  def handle_event("restore_panel_state", %{"panels" => panels}, socket) when is_map(panels) do
    socket =
      Enum.reduce(panels, socket, fn {panel, collapsed}, acc ->
        key = String.to_existing_atom(panel <> "_collapsed")
        assign(acc, key, collapsed)
      end)

    {:noreply, socket}
  end

  def handle_event("restore_panel_state", _, socket), do: {:noreply, socket}

  # NOTE: work_on_ticket now handled via LinearComponent -> handle_info({:linear_component, :work_on_ticket, ticket_id}, ...)
  # But we keep handle_event for backward compatibility with tests and direct phx-click usage
  def handle_event("work_on_ticket", %{"id" => ticket_id}, socket) do
    case InputValidator.validate_general_id(ticket_id) do
      {:ok, validated_ticket_id} ->
        # Show modal immediately with loading state
        socket =
          assign(socket,
            show_work_modal: true,
            work_ticket_id: validated_ticket_id,
            work_ticket_details: nil,
            work_ticket_loading: true,
            work_sent: false,
            work_error: nil
          )

        # Fetch ticket details async
        send(self(), {:fetch_ticket_details, validated_ticket_id})

        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid ticket ID: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("close_work_modal", _, socket) do
    # Delegate to component handler for consistency
    send(self(), {:work_modal_component, :close})
    {:noreply, socket}
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

  # NOTE: Config controls now handled via ConfigComponent -> handle_info({:config_component, ...})

  # Restore model selections from localStorage via JS hook
  def handle_event(
        "restore_model_selections",
        %{"claude_model" => claude_model, "opencode_model" => opencode_model},
        socket
      )
      when is_binary(claude_model) and is_binary(opencode_model) do
    {:noreply, assign(socket, claude_model: claude_model, opencode_model: opencode_model)}
  end

  def handle_event("restore_model_selections", _, socket), do: {:noreply, socket}

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

      result =
        case work_info.type do
          :opencode ->
            # Send to OpenCode session
            ClientFactory.opencode_client().send_message(work_info.session_id, pr_prompt)

          :subagent ->
            # Send to OpenClaw sub-agent via sessions_send
            ClientFactory.openclaw_client().send_message(pr_prompt, channel: "webchat")
        end

      case result do
        {:ok, _} ->
          # Mark ticket as having PR requested
          pr_created = MapSet.put(socket.assigns.pr_created_tickets, ticket_id)
          save_pr_state(pr_created)

          socket =
            socket
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
    # Reject obviously test/placeholder ticket IDs
    if Regex.match?(~r/^(TEST|REVIEW|VERIFY|DUMMY|FAKE|EXAMPLE)/i, ticket_id) do
      {:noreply,
       put_flash(socket, :error, "Invalid ticket ID: #{ticket_id} looks like a test placeholder")}
    else
      handle_super_review_request(ticket_id, socket)
    end
  end

  # Handle request_super_review when id parameter is missing
  def handle_event("request_super_review", _params, socket) do
    {:noreply, put_flash(socket, :error, "Missing ticket ID for super review request")}
  end

  # NOTE: request_pr_super_review now handled via PRsComponent

  # NOTE: fix_pr_issues now handled via PRsComponent

  # NOTE: verify_pr and clear_pr_verification now handled via PRsComponent

  # Clear PR state for a ticket (e.g., when PR is merged)
  def handle_event("clear_ticket_pr", %{"id" => ticket_id}, socket) do
    pr_created = MapSet.delete(socket.assigns.pr_created_tickets, ticket_id)
    save_pr_state(pr_created)
    {:noreply, assign(socket, pr_created_tickets: pr_created)}
  end

  # Execute work on ticket using OpenCode or OpenClaw
  def handle_event("execute_work", _, socket) do
    # Delegate to component handler
    ticket_id = socket.assigns.work_ticket_id
    ticket_details = socket.assigns.work_ticket_details
    coding_pref = socket.assigns.coding_agent_pref
    claude_model = socket.assigns.claude_model
    opencode_model = socket.assigns.opencode_model

    send(
      self(),
      {:work_modal_component, :execute_work,
       {ticket_id, ticket_details, coding_pref, claude_model, opencode_model}}
    )

    {:noreply, socket}
  end

  def handle_event("dismiss_session", %{"id" => id}, socket) do
    dismissed = MapSet.put(socket.assigns.dismissed_sessions, id)
    # Persist to server (survives restarts)
    DashboardState.dismiss_session(id)
    {:noreply, assign(socket, dismissed_sessions: dismissed)}
  end

  # Backward compatibility for tests - delegates to component handler
  def handle_event("clear_progress", _, socket) do
    send(self(), {:live_progress_component, :clear_progress})
    {:noreply, socket}
  end

  # Chat panel removed - using OpenClaw Control UI instead

  # Chat mode toggle removed

  # Keep backward compatibility for tests - delegate to component handler
  def handle_event("clear_completed", _, socket) do
    # Get all completed session IDs and add them to dismissed
    completed_ids =
      socket.assigns.agent_sessions
      |> Enum.filter(fn s -> s.status == Status.completed() end)
      |> Enum.map(fn s -> s.id end)

    dismissed =
      Enum.reduce(completed_ids, socket.assigns.dismissed_sessions, fn id, acc ->
        MapSet.put(acc, id)
      end)

    # Persist to server (survives restarts)
    DashboardState.dismiss_sessions(completed_ids)

    {:noreply, assign(socket, dismissed_sessions: dismissed)}
  end

  # Config model selection - kept for backward compatibility with tests
  def handle_event("select_claude_model", %{"model" => model}, socket) do
    case InputValidator.validate_model_name(model) do
      {:ok, validated_model} ->
        socket = assign(socket, claude_model: validated_model)
        {:noreply, push_model_selections(socket)}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid Claude model: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("select_opencode_model", %{"model" => model}, socket) do
    case InputValidator.validate_model_name(model) do
      {:ok, validated_model} ->
        socket = assign(socket, opencode_model: validated_model)
        {:noreply, push_model_selections(socket)}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid OpenCode model: #{reason}")
        {:noreply, socket}
    end
  end

  @spec handle_super_review_request(String.t(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  defp handle_super_review_request(ticket_id, socket) do
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

    case ClientFactory.openclaw_client().spawn_subagent(review_prompt,
           name: "ticket-review-#{ticket_id}",
           thinking: "medium",
           post_mode: "summary"
         ) do
      {:ok, %{job_id: job_id}} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Review sub-agent spawned for #{ticket_id} (job: #{String.slice(job_id, 0, 8)}...)"
         )}

      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Review sub-agent spawned for #{ticket_id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn review agent: #{inspect(reason)}")}
    end
  end

  # Push current panel state to JS for localStorage persistence AND persist to server
  @spec push_panel_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp push_panel_state(socket) do
    panels = %{
      "config" => socket.assigns.config_collapsed,
      "linear" => socket.assigns.linear_collapsed,
      "chainlink" => socket.assigns.chainlink_collapsed,
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
      "chat" => socket.assigns.chat_collapsed,
      "test_runner" => socket.assigns.test_runner_collapsed,
      "activity" => socket.assigns.activity_collapsed,
      "work_panel" => socket.assigns.work_panel_collapsed,
      "work_river" => socket.assigns.work_river_collapsed,
      "active_tab" => socket.assigns.active_tab
    }

    # Persist to server (survives restarts)
    DashboardState.set_panels(panels)
    # Also push to JS for localStorage (faster client-side restore)
    push_event(socket, "save_panel_state", %{panels: panels})
  end

  # Push active tab state to server (Ticket #127)
  @spec push_tab_state(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp push_tab_state(socket) do
    # Include active_tab in the panels state
    DashboardState.set_panels(%{"active_tab" => socket.assigns.active_tab})
    socket
  end

  # Push current model selections to JS for localStorage persistence AND persist to server
  @spec push_model_selections(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  defp push_model_selections(socket) do
    models = %{
      "claude_model" => socket.assigns.claude_model,
      "opencode_model" => socket.assigns.opencode_model
    }

    # Persist to server (survives restarts)
    DashboardState.set_models(models)
    # Also push to JS for localStorage
    push_event(socket, "save_model_selections", %{models: models})
  end

  # build_agent_activity function moved to DashboardPhoenixWeb.HomeLiveCache for memoization
  # build_tickets_in_progress, build_prs_in_progress, build_chainlink_work_in_progress
  # moved to DashboardPhoenixWeb.HomeLive.WorkProgressBuilder
  # build_graph_data function moved to DashboardPhoenixWeb.HomeLiveCache for memoization

  # Fetch OpenCode sessions if server is running
  @spec fetch_opencode_sessions(opencode_status()) :: list(map())
  defp fetch_opencode_sessions(%{running: true}) do
    case ClientFactory.opencode_client().list_sessions_formatted() do
      {:ok, sessions} -> SessionEnricher.enrich_opencode_sessions(sessions)
      {:error, _} -> []
    end
  end

  defp fetch_opencode_sessions(_), do: []

  # PR state persistence - stores which tickets have PRs created
  @spec pr_state_file() :: String.t()
  defp pr_state_file, do: Paths.pr_state_file()

  @spec load_pr_state() :: MapSet.t()
  defp load_pr_state do
    file = pr_state_file()

    case File.read(file) do
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

  @spec save_pr_state(MapSet.t()) :: :ok
  defp save_pr_state(pr_created) do
    file = pr_state_file()
    content = Jason.encode!(%{"pr_created" => MapSet.to_list(pr_created)})
    File.mkdir_p!(Path.dirname(file))
    FileUtils.atomic_write!(file, content)
  end

  # Linear filter button styling moved to LinearComponent
  # Template moved to home_live.html.heex for cleaner separation

  # ============================================================================
  # HELPER FUNCTIONS FOR TEMPLATE (Ticket #127)
  # ============================================================================

  @doc """
  Determines the overall agent status for tab badge display.
  Returns :running if either OpenCode or Gemini is running, :idle otherwise.
  """
  @spec agent_status(map(), map()) :: :running | :idle
  def agent_status(opencode_status, gemini_status) do
    cond do
      Map.get(opencode_status, :running, false) -> :running
      Map.get(gemini_status, :running, false) -> :running
      true -> :idle
    end
  end

  # ============================================================================
  # TIMER SCHEDULING FUNCTIONS
  # ============================================================================

  # Schedule next process update tick
  @spec schedule_update_processes() :: reference()
  defp schedule_update_processes do
    Process.send_after(self(), :update_processes, 10_000)
  end

  # Schedule next OpenCode sessions refresh tick  
  @spec schedule_refresh_opencode_sessions() :: reference()
  defp schedule_refresh_opencode_sessions do
    Process.send_after(self(), :refresh_opencode_sessions, 15_000)
  end
end
