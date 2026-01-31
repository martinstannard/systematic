defmodule DashboardPhoenixWeb.Live.Components.OpenCodeComponent do
  @moduledoc """
  LiveComponent for displaying and managing OpenCode sessions.

  Extracted from HomeLive to improve code organization and maintainability.
  Shows OpenCode server status, active sessions, and provides controls for
  starting/stopping the server and managing individual sessions.
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:opencode_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_opencode_sessions", _, socket) do
    send(self(), {:opencode_component, :refresh})
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_opencode_server", _, socket) do
    send(self(), {:opencode_component, :start_server})
    {:noreply, socket}
  end

  @impl true
  def handle_event("stop_opencode_server", _, socket) do
    send(self(), {:opencode_component, :stop_server})
    {:noreply, socket}
  end

  @impl true
  def handle_event("close_opencode_session", %{"id" => session_id}, socket) do
    send(self(), {:opencode_component, :close_session, session_id})
    {:noreply, socket}
  end

  @impl true
  def handle_event("request_opencode_pr", %{"id" => session_id}, socket) do
    send(self(), {:opencode_component, :request_pr, session_id})
    {:noreply, socket}
  end

  # Helper functions

  defp opencode_status_badge("active"), do: "px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 text-[10px] animate-pulse"
  defp opencode_status_badge("subagent"), do: "px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-400 text-[10px]"
  defp opencode_status_badge("idle"), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]"
  defp opencode_status_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="glass-panel rounded-lg overflow-hidden">
      <div
        class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
        phx-click="toggle_panel"
        phx-target={@myself}
      >
        <div class="flex items-center space-x-2">
          <span class={"text-xs transition-transform duration-200 " <> if(@opencode_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
          <span class="text-xs font-mono text-accent uppercase tracking-wider">💻 OpenCode</span>
          <%= if @opencode_server_status.running do %>
            <span class="text-[10px] font-mono text-base-content/50"><%= @opencode_sessions_count %></span>
          <% end %>
        </div>
        <%= if @opencode_server_status.running do %>
          <button
            phx-click="refresh_opencode_sessions"
            phx-target={@myself}
            class="text-[10px] text-base-content/40 hover:text-accent"
            onclick="event.stopPropagation()"
          >
            ↻
          </button>
        <% end %>
      </div>

      <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@opencode_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-3 pb-3">
          <%= if not @opencode_server_status.running do %>
            <!-- Server Not Running -->
            <div class="text-center py-4">
              <div class="text-[10px] text-base-content/40 mb-2">ACP Server not running</div>
              <button
                phx-click="start_opencode_server"
                phx-target={@myself}
                class="text-xs px-3 py-1.5 rounded bg-success/20 text-success hover:bg-success/40"
              >
                ▶ Start Server
              </button>
            </div>
          <% else %>
            <!-- Server Controls -->
            <div class="flex items-center justify-between mb-3 pb-2 border-b border-white/5">
              <div class="flex items-center space-x-2 text-[10px] font-mono">
                <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
                <span class="text-success">Running on :<%= @opencode_server_status.port %></span>
              </div>
              <button
                phx-click="stop_opencode_server"
                phx-target={@myself}
                class="text-[10px] px-2 py-0.5 rounded bg-error/20 text-error hover:bg-error/40"
              >
                Stop
              </button>
            </div>

            <!-- Sessions List -->
            <div class="space-y-2 max-h-[300px] overflow-y-auto">
              <%= if @opencode_sessions == [] do %>
                <div class="text-xs text-base-content/40 py-4 text-center font-mono">No active sessions</div>
              <% end %>
              <%= for session <- @opencode_sessions do %>
                <div class="px-2 py-2 rounded hover:bg-white/5 text-xs font-mono border border-white/5">
                  <!-- Session Header -->
                  <div class="flex items-start justify-between mb-1">
                    <div class="flex items-center space-x-2 min-w-0">
                      <span class={opencode_status_badge(session.status)}><%= session.status %></span>
                      <span class="text-white truncate" title={session.title || session.slug}><%= session.slug %></span>
                    </div>

                    <!-- Action Buttons -->
                    <div class="flex items-center space-x-1 ml-2">
                      <%= if session.status in ["active", "idle"] do %>
                        <button
                          phx-click="request_opencode_pr"
                          phx-target={@myself}
                          phx-value-id={session.id}
                          class="px-1.5 py-0.5 rounded bg-purple-500/20 text-purple-400 hover:bg-purple-500/40 text-[10px]"
                          title="Request PR creation"
                        >
                          PR
                        </button>
                      <% end %>
                      <button
                        phx-click="close_opencode_session"
                        phx-target={@myself}
                        phx-value-id={session.id}
                        class="px-1.5 py-0.5 rounded bg-error/20 text-error hover:bg-error/40 text-[10px]"
                        title="Close session"
                      >
                        ✕
                      </button>
                    </div>
                  </div>

                  <!-- Session Title (if different from slug) -->
                  <%= if session.title && session.title != session.slug do %>
                    <div class="text-[10px] text-base-content/50 truncate mb-1" title={session.title}>
                      <%= session.title %>
                    </div>
                  <% end %>

                  <!-- File Changes -->
                  <%= if session.file_changes.files > 0 do %>
                    <div class="flex items-center space-x-2 text-[10px]">
                      <span class="text-base-content/40"><%= session.file_changes.files %> files</span>
                      <span class="text-green-400">+<%= session.file_changes.additions %></span>
                      <span class="text-red-400">-<%= session.file_changes.deletions %></span>
                    </div>
                  <% end %>

                  <!-- Directory -->
                  <%= if session.directory do %>
                    <div class="text-[10px] text-base-content/30 truncate mt-1" title={session.directory}>
                      📁 <%= session.directory %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
