defmodule DashboardPhoenixWeb.HomeLive do
  use DashboardPhoenixWeb, :live_view
  
  alias DashboardPhoenix.ProcessMonitor
  alias DashboardPhoenix.SessionBridge
  alias DashboardPhoenix.StatsMonitor

  def mount(_params, _session, socket) do
    if connected?(socket) do
      SessionBridge.subscribe()
      StatsMonitor.subscribe()
      Process.send_after(self(), :update_processes, 100)
      :timer.send_interval(2_000, :update_processes)
    end

    processes = ProcessMonitor.list_processes()
    sessions = SessionBridge.get_sessions()
    progress = SessionBridge.get_progress()
    stats = StatsMonitor.get_stats()
    
    socket = assign(socket,
      process_stats: ProcessMonitor.get_stats(processes),
      recent_processes: processes,
      agent_sessions: sessions,
      agent_progress: progress,
      usage_stats: stats
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

  # Handle stats updates
  def handle_info({:stats_updated, stats}, socket) do
    {:noreply, assign(socket, usage_stats: stats)}
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
    progress_file = Application.get_env(:dashboard_phoenix, :progress_file, "/tmp/agent-progress.jsonl")
    File.write(progress_file, "")
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

      <!-- Usage Stats -->
      <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <!-- OpenCode Stats -->
        <div class="glass-panel rounded-lg p-3">
          <div class="text-[10px] font-mono text-accent uppercase tracking-wider mb-2">📊 OpenCode (Gemini)</div>
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
                <!-- Header -->
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
                
                <!-- Agent Info -->
                <div class="flex items-center space-x-2 mb-2">
                  <span class={"text-[10px] font-mono px-1.5 py-0.5 rounded " <> model_badge(session.model)}>
                    <%= String.upcase(to_string(session.model || "claude")) %>
                  </span>
                  <span class="text-[10px] font-mono text-base-content/50">
                    <%= session.agent_type || "subagent" %>
                  </span>
                  <%= if session.runtime do %>
                    <span class="text-[10px] font-mono text-base-content/50">
                      ⏱ <%= session.runtime %>
                    </span>
                  <% end %>
                </div>
                
                <!-- Task -->
                <div class="text-xs text-base-content/70 mb-2 line-clamp-2"><%= session.task %></div>
                
                <!-- Stats -->
                <%= if session.total_tokens && session.total_tokens > 0 do %>
                  <div class="flex items-center space-x-3 mb-2 text-[10px] font-mono">
                    <span class="text-primary">↓<%= format_tokens(session.tokens_in) %></span>
                    <span class="text-secondary">↑<%= format_tokens(session.tokens_out) %></span>
                    <%= if session.cost && session.cost > 0 do %>
                      <span class="text-success">$<%= Float.round(session.cost, 3) %></span>
                    <% end %>
                  </div>
                <% end %>
                
                <!-- Current Action -->
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
