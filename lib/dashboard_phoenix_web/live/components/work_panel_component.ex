defmodule DashboardPhoenixWeb.Live.Components.WorkPanelComponent do
  @moduledoc """
  Unified Work Panel showing all coding agents in a single view.
  
  Uses AgentCardComponent for consistent display of:
  - Claude sub-agents (🟣)
  - OpenCode sessions (🔷)
  - Gemini CLI (✨)
  
  Each card shows:
  - Agent icon and type indicator
  - Task/session name
  - Duration (real-time for running agents)
  - Color-coded state (running=green, completed=blue, failed=red, idle=gray)
  - **Expandable details** with recent messages, token usage, cost, etc.
  """
  use DashboardPhoenixWeb, :live_component
  
  alias DashboardPhoenix.Status
  alias DashboardPhoenixWeb.Live.Components.AgentCardComponent

  @impl true
  def update(assigns, socket) do
    # Build unified agent list for cards with full details
    agents = build_agent_list(assigns)
    
    # Count active agents for header
    active_count = Enum.count(agents, fn a -> 
      Map.get(a, :status) in [Status.running(), Status.active(), Status.idle()]
    end)
    
    # Count by type for summary
    type_counts = agents
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {type, list} -> {type, length(list)} end)
    |> Enum.into(%{})
    
    updated_assigns = assigns
    |> Map.put(:agents, agents)
    |> Map.put(:active_count, active_count)
    |> Map.put(:type_counts, type_counts)

    {:ok, assign(socket, updated_assigns)}
  end

  defp build_agent_list(assigns) do
    claude_agents = build_claude_agents(assigns)
    opencode_agents = build_opencode_agents(assigns)
    gemini_agent = build_gemini_agent(assigns)
    
    # Combine and sort: running first, then by name
    (claude_agents ++ opencode_agents ++ gemini_agent)
    |> Enum.sort_by(fn a -> 
      status = Map.get(a, :status, Status.idle())
      priority = cond do
        status == Status.running() -> 0
        status == Status.active() -> 0
        status == Status.idle() -> 1
        true -> 2
      end
      {priority, Map.get(a, :name, "")}
    end)
  end

  defp build_claude_agents(assigns) do
    show_completed = Map.get(assigns, :show_completed, true)
    dismissed_sessions = Map.get(assigns, :dismissed_sessions, MapSet.new())
    chainlink_work = Map.get(assigns, :chainlink_work_in_progress, %{})
    
    assigns.agent_sessions
    |> Enum.reject(fn s -> Map.get(s, :session_key) == "agent:main:main" end)
    |> Enum.filter(fn s -> s.status in [Status.running(), Status.idle(), Status.completed()] end)
    |> Enum.reject(fn s -> MapSet.member?(dismissed_sessions, Map.get(s, :id)) end)
    |> Enum.filter(fn s -> show_completed or s.status != Status.completed() end)
    |> Enum.take(10)  # Show more agents now that they're expandable
    |> Enum.map(fn s ->
      # Get recent actions (limit to last 5)
      recent_actions = s
      |> Map.get(:recent_actions, [])
      |> Enum.take(-5)
      
      # Try to find stored work info for this session (by matching label to ticket-N pattern)
      label = Map.get(s, :label, "")
      stored_work = find_stored_work_info(label, chainlink_work)
      
      # Use stored agent_type/model if available, otherwise fall back to session data
      agent_type = Map.get(stored_work, :agent_type) || "claude"
      model = Map.get(s, :model) || Map.get(stored_work, :model)
      
      %{
        id: Map.get(s, :id, "claude-#{:erlang.phash2(s)}"),
        type: agent_type,
        model: model,
        name: label || String.slice(Map.get(s, :id, ""), 0, 12),
        task: Map.get(s, :task_summary),
        status: s.status,
        runtime: Map.get(s, :runtime),
        updated_at: Map.get(s, :updated_at),
        created_at: Map.get(s, :created_at),
        # Extended details for expansion
        tokens_in: Map.get(s, :tokens_in, 0),
        tokens_out: Map.get(s, :tokens_out, 0),
        cost: Map.get(s, :cost, 0),
        current_action: Map.get(s, :current_action),
        recent_actions: recent_actions,
        result_snippet: Map.get(s, :result_snippet)
      }
    end)
  end
  
  # Find stored work info by matching session label to chainlink ticket patterns
  defp find_stored_work_info(label, chainlink_work) when is_binary(label) and is_map(chainlink_work) do
    # Match "ticket-N" pattern in label to find the issue ID
    case Regex.run(~r/ticket-(\d+)/, label) do
      [_, issue_id_str] ->
        case Integer.parse(issue_id_str) do
          {issue_id, ""} -> Map.get(chainlink_work, issue_id, %{})
          _ -> %{}
        end
      _ -> %{}
    end
  end
  defp find_stored_work_info(_, _), do: %{}

  defp build_opencode_agents(assigns) do
    assigns.opencode_sessions
    |> Enum.take(10)  # Show more agents now that they're expandable
    |> Enum.map(fn s ->
      # OpenCode sessions may have different field names
      recent_actions = s
      |> Map.get(:recent_actions, [])
      |> Enum.take(-5)
      
      %{
        id: Map.get(s, :id, "opencode-#{s.slug}"),
        type: "opencode",
        model: Map.get(s, :model),
        name: s.slug,
        task: s.title,
        status: s.status,
        runtime: Map.get(s, :runtime),
        start_time: Map.get(s, :start_time),
        # Extended details for expansion
        tokens_in: Map.get(s, :tokens_in, 0),
        tokens_out: Map.get(s, :tokens_out, 0),
        cost: Map.get(s, :cost, 0),
        current_action: Map.get(s, :current_action),
        recent_actions: recent_actions,
        result_snippet: Map.get(s, :result_snippet)
      }
    end)
  end

  defp build_gemini_agent(assigns) do
    status = assigns.gemini_server_status
    if status.running do
      busy = Map.get(status, :busy, false)
      
      # Extract last few lines as recent activity
      recent_output = if assigns.gemini_output != "" do
        assigns.gemini_output
        |> String.split("\n")
        |> Enum.filter(&(String.trim(&1) != ""))
        |> Enum.take(-5)
      else
        []
      end
      
      last_activity = if recent_output != [] do
        List.last(recent_output) |> String.slice(0, 100)
      else
        nil
      end
      
      [%{
        id: "gemini-cli",
        type: "gemini",
        model: "gemini-2.0-flash",
        name: "Gemini CLI",
        task: last_activity,
        status: if(busy, do: Status.running(), else: Status.idle()),
        runtime: nil,
        start_time: nil,
        # Extended details for expansion
        tokens_in: 0,
        tokens_out: 0,
        cost: 0,
        current_action: if(busy, do: last_activity, else: nil),
        recent_actions: recent_output,
        result_snippet: nil
      }]
    else
      []
    end
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:work_panel_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-work overflow-hidden" id="work-panel">
      <div
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
        role="button"
        tabindex="0"
        aria-expanded={if(@work_panel_collapsed, do: "false", else: "true")}
        aria-controls="work-panel-content"
        aria-label="Toggle Work panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@work_panel_collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">⚡</span>
          <span class="text-panel-label text-accent">Work</span>
          <span class="text-xs font-mono text-base-content/50"><%= length(@agents) %></span>
          <%= if @active_count > 0 do %>
            <span class="status-beacon text-success"></span>
            <span class="px-1.5 py-0.5 bg-green-500/20 text-green-400 text-xs rounded">
              <%= @active_count %> active
            </span>
          <% end %>
        </div>
        
        <!-- Agent type legend -->
        <div class="flex items-center gap-3 text-xs">
          <span class={"flex items-center gap-1 " <> if(Map.get(@type_counts, "claude", 0) > 0, do: "text-purple-400", else: "text-base-content/40")}>
            <span>🟣</span><span>Claude</span>
            <%= if Map.get(@type_counts, "claude", 0) > 0 do %><span class="font-mono">(<%= @type_counts["claude"] %>)</span><% end %>
          </span>
          <span class={"flex items-center gap-1 " <> if(Map.get(@type_counts, "opencode", 0) > 0, do: "text-blue-400", else: "text-base-content/40")}>
            <span>🔷</span><span>OpenCode</span>
            <%= if Map.get(@type_counts, "opencode", 0) > 0 do %><span class="font-mono">(<%= @type_counts["opencode"] %>)</span><% end %>
          </span>
          <span class={"flex items-center gap-1 " <> if(Map.get(@type_counts, "gemini", 0) > 0, do: "text-amber-400", else: "text-base-content/40")}>
            <span>✨</span><span>Gemini</span>
            <%= if Map.get(@type_counts, "gemini", 0) > 0 do %><span class="font-mono">(<%= @type_counts["gemini"] %>)</span><% end %>
          </span>
        </div>
      </div>

      <div id="work-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@work_panel_collapsed, do: "max-h-0", else: "max-h-[1000px]")}>
        <div class="px-4 pb-4">
          <%= if @agents == [] do %>
            <div class="text-xs text-base-content/40 py-8 text-center font-mono">
              No active agents
            </div>
          <% else %>
            <!-- Hint about expandable cards -->
            <div class="text-xs text-base-content/40 mb-3 text-center">
              Click cards to expand details
            </div>
            
            <div class="agent-cards-grid">
              <%= for agent <- @agents do %>
                <.live_component 
                  module={AgentCardComponent}
                  id={"agent-card-#{agent.id}"}
                  agent={agent}
                  type={Map.get(agent, :type)}
                />
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
