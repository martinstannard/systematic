defmodule DashboardPhoenixWeb.Live.Components.WorkPanelComponent do
  @moduledoc """
  Unified Work Panel showing all coding agents in a single view.
  
  Uses AgentCardComponent for consistent display of:
  - Claude sub-agents (🟣)
  - OpenCode sessions (🔷)
  - Gemini CLI (✨)
  
  Each card shows:
  - Agent icon
  - Task/session name
  - Duration (real-time for running agents)
  - Color-coded state (running=green, completed=blue, failed=red, idle=gray)
  """
  use DashboardPhoenixWeb, :live_component
  
  alias DashboardPhoenixWeb.Live.Components.AgentCardComponent

  @impl true
  def update(assigns, socket) do
    # Build unified agent list for cards
    agents = build_agent_list(assigns)
    
    # Count active agents for header
    active_count = Enum.count(agents, fn a -> 
      Map.get(a, :status) in ["running", "active", "idle"]
    end)
    
    updated_assigns = assigns
    |> Map.put(:agents, agents)
    |> Map.put(:active_count, active_count)

    {:ok, assign(socket, updated_assigns)}
  end

  defp build_agent_list(assigns) do
    claude_agents = build_claude_agents(assigns)
    opencode_agents = build_opencode_agents(assigns)
    gemini_agent = build_gemini_agent(assigns)
    
    # Combine and sort: running first, then by name
    (claude_agents ++ opencode_agents ++ gemini_agent)
    |> Enum.sort_by(fn a -> 
      status = Map.get(a, :status, "idle")
      priority = case status do
        "running" -> 0
        "active" -> 0
        "idle" -> 1
        _ -> 2
      end
      {priority, Map.get(a, :name, "")}
    end)
  end

  defp build_claude_agents(assigns) do
    assigns.agent_sessions
    |> Enum.reject(fn s -> Map.get(s, :session_key) == "agent:main:main" end)
    |> Enum.filter(fn s -> s.status in ["running", "idle", "completed"] end)
    |> Enum.take(5)
    |> Enum.map(fn s ->
      %{
        id: Map.get(s, :id, "claude-#{:erlang.phash2(s)}"),
        type: "claude",
        model: Map.get(s, :model),
        name: Map.get(s, :label) || String.slice(Map.get(s, :id, ""), 0, 12),
        task: Map.get(s, :task_summary),
        status: s.status,
        runtime: Map.get(s, :runtime),
        updated_at: Map.get(s, :updated_at),
        created_at: Map.get(s, :created_at)
      }
    end)
  end

  defp build_opencode_agents(assigns) do
    assigns.opencode_sessions
    |> Enum.take(5)
    |> Enum.map(fn s ->
      %{
        id: Map.get(s, :id, "opencode-#{s.slug}"),
        type: "opencode",
        name: s.slug,
        task: s.title,
        status: s.status,
        runtime: nil,
        start_time: nil
      }
    end)
  end

  defp build_gemini_agent(assigns) do
    status = assigns.gemini_server_status
    if status.running do
      busy = Map.get(status, :busy, false)
      last_activity = if assigns.gemini_output != "" do
        assigns.gemini_output
        |> String.split("\n")
        |> Enum.take(-1)
        |> Enum.join()
        |> String.slice(0, 50)
      else
        nil
      end
      
      [%{
        id: "gemini-cli",
        type: "gemini",
        name: "Gemini CLI",
        task: last_activity,
        status: if(busy, do: "running", else: "idle"),
        runtime: nil,
        start_time: nil
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
            <span class="px-1.5 py-0.5 bg-green-500/20 text-green-400 text-xs">
              <%= @active_count %> active
            </span>
          <% end %>
        </div>
      </div>

      <div id="work-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@work_panel_collapsed, do: "max-h-0", else: "max-h-[600px]")}>
        <div class="px-3 pb-3 space-y-2">
          <%= if @agents == [] do %>
            <div class="text-xs text-base-content/40 py-4 text-center font-mono">
              No active agents
            </div>
          <% else %>
            <%= for agent <- @agents do %>
              <.live_component 
                module={AgentCardComponent}
                id={"agent-card-#{agent.id}"}
                agent={agent}
                type={Map.get(agent, :type)}
              />
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
