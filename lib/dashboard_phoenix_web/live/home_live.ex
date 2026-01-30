defmodule DashboardPhoenixWeb.HomeLive do
  use DashboardPhoenixWeb, :live_view
  
  alias DashboardPhoenix.ProcessMonitor
  alias DashboardPhoenix.SessionBridge

  def mount(_params, _session, socket) do
    if connected?(socket) do
      SessionBridge.subscribe()
      Process.send_after(self(), :update_processes, 100)
      :timer.send_interval(2_000, :update_processes)
    end

    processes = ProcessMonitor.list_processes()
    sessions = SessionBridge.get_sessions()
    progress = SessionBridge.get_progress()
    
    socket = assign(socket,
      process_stats: ProcessMonitor.get_stats(processes),
      recent_processes: processes,
      agent_sessions: sessions,
      agent_progress: progress
    )

    {:ok, socket}
  end

  # Handle live progress updates
  def handle_info({:progress, events}, socket) do
    updated = (socket.assigns.agent_progress ++ events) |> Enum.take(-100)
    {:noreply, assign(socket, agent_progress: updated)}
  end

  # Handle session updates
  def handle_info({:sessions, sessions}, socket) do
    {:noreply, assign(socket, agent_sessions: sessions)}
  end

  def handle_info(:update_processes, socket) do
    processes = ProcessMonitor.list_processes()
    socket = assign(socket,
      process_stats: ProcessMonitor.get_stats(processes),
      recent_processes: processes
    )
    {:noreply, socket}
  end

  def handle_event("kill_agent", %{"id" => _id}, socket) do
    socket = put_flash(socket, :info, "Kill not implemented for sub-agents yet")
    {:noreply, socket}
  end

  def handle_event("clear_progress", _, socket) do
    File.write("/tmp/agent-progress.jsonl", "")
    {:noreply, assign(socket, agent_progress: [])}
  end

  defp format_time(nil), do: ""
  defp format_time(ts) when is_integer(ts) do
    ts
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end
  defp format_time(_), do: ""

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
  defp status_badge("done"), do: "bg-success/20 text-success"
  defp status_badge("error"), do: "bg-error/20 text-error"
  defp status_badge(_), do: "bg-base-content/10 text-base-content/60"

  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <!-- Header -->
      <div class="glass-panel rounded-lg px-4 py-2 flex items-center justify-between">
        <div class="flex items-center space-x-4">
          <h1 class="text-sm font-bold tracking-widest text-white">SYSTEMATIC</h1>
          <span class="text-[10px] text-base-content/60 font-mono">AGENT CONTROL</span>
        </div>
        <div class="flex items-center space-x-4 text-xs font-mono">
          <span class="text-success font-bold"><%= length(@agent_sessions) %></span>
          <span class="text-base-content/60">AGENTS</span>
          <span class="text-primary font-bold"><%= length(@agent_progress) %></span>
          <span class="text-base-content/60">EVENTS</span>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <!-- Agent Sessions Panel -->
        <div class="lg:col-span-1 space-y-3">
          <div class="flex items-center justify-between px-1">
            <span class="text-xs font-mono text-accent uppercase tracking-wider">🤖 Sub-Agents</span>
          </div>
          
          <%= if @agent_sessions == [] do %>
            <div class="glass-panel rounded-lg p-4 text-center">
              <div class="text-base-content/40 font-mono text-xs mb-2">[NO ACTIVE AGENTS]</div>
              <div class="text-base-content/60 text-xs">Spawn a sub-agent to begin</div>
            </div>
          <% else %>
            <%= for session <- @agent_sessions do %>
              <div class={"glass-panel rounded-lg p-3 border-l-4 " <> if(session.status == "running", do: "border-l-warning", else: "border-l-success")}>
                <div class="flex items-center justify-between mb-2">
                  <div class="flex items-center space-x-2">
                    <%= if session.status == "running" do %>
                      <span class="throbber"></span>
                    <% else %>
                      <span class="text-success">✓</span>
                    <% end %>
                    <span class="text-sm font-mono text-white font-bold"><%= session.label || session.id %></span>
                  </div>
                  <span class={"text-[10px] font-mono px-1.5 py-0.5 rounded " <> status_badge(session.status)}>
                    <%= String.upcase(session.status || "unknown") %>
                  </span>
                </div>
                <div class="text-xs text-base-content/70 mb-2 line-clamp-2"><%= session.task %></div>
                <%= if session.current_action do %>
                  <div class="text-[10px] font-mono text-warning flex items-center space-x-1">
                    <span class="inline-block w-1 h-1 bg-warning rounded-full animate-ping"></span>
                    <span>→ <%= session.current_action %></span>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Live Progress Feed -->
        <div class="lg:col-span-2 space-y-3">
          <div class="flex items-center justify-between px-1">
            <span class="text-xs font-mono text-accent uppercase tracking-wider">📡 Live Progress</span>
            <button phx-click="clear_progress" class="text-[10px] font-mono px-2 py-0.5 rounded bg-base-content/10 text-base-content/60 hover:bg-base-content/20">
              CLEAR
            </button>
          </div>
          
          <div class="glass-panel rounded-lg p-3 h-[400px] overflow-y-auto font-mono text-xs" id="progress-feed" phx-hook="ScrollBottom">
            <%= if @agent_progress == [] do %>
              <div class="text-base-content/40 text-center py-8">
                Waiting for agent activity...
              </div>
            <% else %>
              <%= for event <- @agent_progress do %>
                <div class="flex items-start space-x-2 py-1 border-b border-white/5 last:border-0">
                  <span class="text-base-content/40 w-16 flex-shrink-0"><%= format_time(event.ts) %></span>
                  <span class="text-accent w-20 flex-shrink-0 truncate"><%= event.agent %></span>
                  <span class={"w-12 flex-shrink-0 font-bold " <> action_color(event.action)}><%= event.action %></span>
                  <span class="text-base-content/70 truncate flex-1" title={event.target}><%= event.target %></span>
                  <%= if event.status == "error" do %>
                    <span class="text-error">✗</span>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>

      <!-- System Processes -->
      <div class="space-y-3">
        <div class="flex items-center px-1">
          <span class="text-xs font-mono text-base-content/60 uppercase tracking-wider">⚙️ System Processes (<%= length(@recent_processes) %>)</span>
        </div>
        <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-3">
          <%= for process <- @recent_processes do %>
            <div class={"glass-panel rounded-lg p-3 border-l-4 " <> case process.status do
              "busy" -> "border-l-warning"
              "idle" -> "border-l-success"
              _ -> "border-l-base-content/20"
            end}>
              <div class="text-xs font-mono text-white bg-black/30 rounded px-2 py-1 mb-2 truncate">
                <span class="text-accent">$</span> <%= process.command %>
              </div>
              <div class="flex items-center justify-between text-[10px] font-mono">
                <span class="text-base-content/60"><%= process.name %></span>
                <span class="text-base-content/60">CPU: <%= Map.get(process, :cpu_usage, "?") %></span>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
