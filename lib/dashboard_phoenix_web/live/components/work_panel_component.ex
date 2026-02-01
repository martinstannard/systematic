defmodule DashboardPhoenixWeb.Live.Components.WorkPanelComponent do
  @moduledoc """
  Unified Work Panel showing all coding agents in a single view.
  
  Displays:
  - Claude sub-agents (active count + recent tasks)
  - OpenCode sessions (session count + recent sessions)
  - Gemini CLI (running status + last activity)
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    # Pre-calculate Claude sub-agent data
    sub_agent_sessions = Enum.reject(assigns.agent_sessions, fn s ->
      Map.get(s, :session_key) == "agent:main:main"
    end)
    
    claude_active = Enum.count(sub_agent_sessions, fn s -> s.status in ["running", "idle"] end)
    claude_recent = sub_agent_sessions
    |> Enum.filter(fn s -> s.status in ["running", "idle"] end)
    |> Enum.take(3)
    |> Enum.map(fn s ->
      %{
        label: Map.get(s, :label) || String.slice(Map.get(s, :id, ""), 0, 8),
        status: s.status,
        task: Map.get(s, :task_summary)
      }
    end)
    
    # Pre-calculate OpenCode data
    opencode_active = length(assigns.opencode_sessions)
    opencode_recent = assigns.opencode_sessions
    |> Enum.take(3)
    |> Enum.map(fn s ->
      %{
        slug: s.slug,
        status: s.status,
        title: s.title
      }
    end)
    
    # Pre-calculate Gemini data
    gemini_running = assigns.gemini_server_status.running
    gemini_busy = Map.get(assigns.gemini_server_status, :busy, false)
    gemini_last_activity = if assigns.gemini_output != "" do
      assigns.gemini_output
      |> String.split("\n")
      |> Enum.take(-3)
      |> Enum.join("\n")
      |> String.slice(0, 150)
    else
      nil
    end

    updated_assigns = assigns
    |> Map.put(:claude_active, claude_active)
    |> Map.put(:claude_recent, claude_recent)
    |> Map.put(:opencode_active, opencode_active)
    |> Map.put(:opencode_recent, opencode_recent)
    |> Map.put(:gemini_running, gemini_running)
    |> Map.put(:gemini_busy, gemini_busy)
    |> Map.put(:gemini_last_activity, gemini_last_activity)

    {:ok, assign(socket, updated_assigns)}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:work_panel_component, :toggle_panel})
    {:noreply, socket}
  end

  # Status badge styling
  defp status_class("running"), do: "bg-warning/20 text-warning"
  defp status_class("active"), do: "bg-green-500/20 text-green-400"
  defp status_class("idle"), do: "bg-info/20 text-info"
  defp status_class(_), do: "bg-base-content/10 text-base-content/60"

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
          <%= if @claude_active > 0 || @opencode_active > 0 || @gemini_running do %>
            <span class="status-beacon text-success"></span>
          <% end %>
        </div>
      </div>

      <div id="work-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@work_panel_collapsed, do: "max-h-0", else: "max-h-[600px]")}>
        <div class="px-3 pb-3 space-y-2">
          <!-- Claude Sub-Agents Card -->
          <div class="panel-status border border-accent/20 p-2">
            <div class="flex items-center justify-between mb-1.5">
              <div class="flex items-center space-x-2">
                <span class="text-sm">🤖</span>
                <span class="text-xs font-medium text-white">Claude</span>
              </div>
              <span class={"px-1.5 py-0.5 text-xs " <> if(@claude_active > 0, do: "bg-warning/20 text-warning", else: "bg-base-content/10 text-base-content/50")}>
                <%= @claude_active %> active
              </span>
            </div>
            <%= if @claude_recent != [] do %>
              <div class="space-y-1">
                <%= for session <- @claude_recent do %>
                  <div class="flex items-center space-x-2 text-xs">
                    <%= if session.status == "running" do %>
                      <span class="throbber-small flex-shrink-0"></span>
                    <% else %>
                      <span class="text-info">○</span>
                    <% end %>
                    <span class="text-base-content/70 truncate flex-1" title={session.task || session.label}>
                      <%= session.label %>
                    </span>
                    <span class={status_class(session.status) <> " px-1 py-0.5 text-xs"}>
                      <%= session.status %>
                    </span>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="text-xs text-base-content/40 italic">No active sub-agents</div>
            <% end %>
          </div>

          <!-- OpenCode Card -->
          <div class="panel-status border border-accent/20 p-2">
            <div class="flex items-center justify-between mb-1.5">
              <div class="flex items-center space-x-2">
                <span class="text-sm">💻</span>
                <span class="text-xs font-medium text-white">OpenCode</span>
              </div>
              <span class={"px-1.5 py-0.5 text-xs " <> if(@opencode_active > 0, do: "bg-blue-500/20 text-blue-400", else: "bg-base-content/10 text-base-content/50")}>
                <%= @opencode_active %> sessions
              </span>
            </div>
            <%= if @opencode_recent != [] do %>
              <div class="space-y-1">
                <%= for session <- @opencode_recent do %>
                  <div class="flex items-center space-x-2 text-xs">
                    <%= if session.status == "active" do %>
                      <span class="throbber-small flex-shrink-0"></span>
                    <% else %>
                      <span class="text-blue-400">○</span>
                    <% end %>
                    <span class="text-base-content/70 truncate flex-1" title={session.title || session.slug}>
                      <%= session.slug %>
                    </span>
                    <span class={status_class(session.status) <> " px-1 py-0.5 text-xs"}>
                      <%= session.status %>
                    </span>
                  </div>
                <% end %>
              </div>
            <% else %>
              <div class="text-xs text-base-content/40 italic">No active sessions</div>
            <% end %>
          </div>

          <!-- Gemini Card -->
          <div class="panel-status border border-accent/20 p-2">
            <div class="flex items-center justify-between mb-1.5">
              <div class="flex items-center space-x-2">
                <span class="text-sm">✨</span>
                <span class="text-xs font-medium text-white">Gemini</span>
              </div>
              <%= if @gemini_running do %>
                <%= if @gemini_busy do %>
                  <span class="px-1.5 py-0.5 text-xs bg-warning/20 text-warning animate-pulse">running</span>
                <% else %>
                  <span class="px-1.5 py-0.5 text-xs bg-green-500/20 text-green-400">ready</span>
                <% end %>
              <% else %>
                <span class="px-1.5 py-0.5 text-xs bg-base-content/10 text-base-content/50">stopped</span>
              <% end %>
            </div>
            <%= if @gemini_last_activity do %>
              <div class="text-xs text-base-content/60 truncate font-mono" title={@gemini_last_activity}>
                <%= @gemini_last_activity %>
              </div>
            <% else %>
              <div class="text-xs text-base-content/40 italic">
                <%= if @gemini_running, do: "No recent activity", else: "Not running" %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
