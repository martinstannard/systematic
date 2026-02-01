defmodule DashboardPhoenixWeb.Live.Components.OpenCodeComponent do
  @moduledoc """
  LiveComponent for displaying and managing OpenCode sessions.

  Extracted from HomeLive to improve code organization and maintainability.
  Shows OpenCode server status, active sessions, and provides controls for
  starting/stopping the server and managing individual sessions.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator
  alias DashboardPhoenix.Status

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
    case InputValidator.validate_session_id(session_id) do
      {:ok, validated_session_id} ->
        send(self(), {:opencode_component, :close_session, validated_session_id})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid session ID: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("request_opencode_pr", %{"id" => session_id}, socket) do
    case InputValidator.validate_session_id(session_id) do
      {:ok, validated_session_id} ->
        send(self(), {:opencode_component, :request_pr, validated_session_id})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid session ID: #{reason}")
        {:noreply, socket}
    end
  end

  # Helper functions

  defp opencode_status_badge(status) do
    cond do
      status == Status.active() -> "px-2 py-1 bg-green-500/20 text-green-400 text-xs rounded"
      status == "subagent" -> "px-2 py-1 bg-purple-500/20 text-purple-400 text-xs rounded"
      status == Status.idle() -> "px-2 py-1 bg-blue-500/20 text-blue-400 text-xs rounded"
      true -> "px-2 py-1 bg-base-content/10 text-base-content/60 text-xs rounded"
    end
  end

  defp opencode_status_symbol(status) do
    cond do
      status == Status.active() -> "●"
      status == "subagent" -> "◆"
      status == Status.idle() -> "○"
      true -> "◌"
    end
  end

  defp opencode_status_text(status) do
    cond do
      status == Status.active() -> Status.active()
      status == "subagent" -> "subagent"
      status == Status.idle() -> Status.idle()
      true -> status || "unknown"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-work overflow-hidden">
      <div
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
        role="button"
        tabindex="0"
        aria-expanded={if(@opencode_collapsed, do: "false", else: "true")}
        aria-controls="opencode-panel-content"
        aria-label="Toggle OpenCode panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@opencode_collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">💻</span>
          <span class="text-panel-label text-accent">OpenCode</span>
          <%= if @opencode_server_status.running do %>
            <span class="status-beacon text-success" title="Server Online" aria-label="Online">●</span>
            <span class="text-xs font-mono text-base-content/50"><%= length(@opencode_sessions) %></span>
          <% end %>
        </div>
        <%= if @opencode_server_status.running do %>
          <button
            phx-click="refresh_opencode_sessions"
            phx-target={@myself}
            class="text-xs text-base-content/40 hover:text-accent"
            onclick="event.stopPropagation()"
            aria-label="Refresh OpenCode sessions"
          >
            ↻
          </button>
        <% end %>
      </div>

      <div id="opencode-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@opencode_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-5 pb-5 pt-2">
          <%= if not @opencode_server_status.running do %>
            <!-- Server Not Running -->
            <div class="text-center py-4">
              <div class="text-xs text-base-content/40 mb-2">ACP Server not running</div>
              <button
                phx-click="start_opencode_server"
                phx-target={@myself}
                class="text-xs px-3 py-2 bg-success/20 text-success hover:bg-success/40 rounded"
                aria-label="Start OpenCode ACP server"
              >
                ▶ Start Server
              </button>
            </div>
          <% else %>
            <!-- Server Controls -->
            <div class="flex items-center justify-between mb-3 pb-2 border-b border-white/5">
              <div class="flex items-center space-x-2 text-xs font-mono">
                <span class="w-2 h-2 bg-success" aria-label="Server running"></span>
                <span class="text-success">Running on :<%= @opencode_server_status.port %></span>
              </div>
              <button
                phx-click="stop_opencode_server"
                phx-target={@myself}
                class="text-xs px-3 py-1 bg-error/20 text-error hover:bg-error/40 rounded"
                aria-label="Stop OpenCode ACP server"
              >
                Stop
              </button>
            </div>

            <!-- Sessions List -->
            <div class="space-y-4 max-h-[300px] overflow-y-auto" role="region" aria-live="polite" aria-label="OpenCode sessions list">
              <%= if @opencode_sessions == [] do %>
                <div class="text-xs text-base-content/40 py-4 text-center font-mono">No active sessions</div>
              <% end %>
              <%= for session <- @opencode_sessions do %>
                <div class="px-3 py-3 panel-status hover:bg-accent/10 text-xs font-mono border border-accent/20 hover:border-accent/40 transition-all rounded">
                  <!-- Session Header -->
                  <div class="flex items-start justify-between mb-1">
                    <div class="flex items-center space-x-2 min-w-0">
                      <span class={opencode_status_badge(session.status)} title={"Session status: " <> String.upcase(opencode_status_text(session.status))}>
                        <%= opencode_status_symbol(session.status) %> <%= opencode_status_text(session.status) %>
                      </span>
                      <span class="text-white truncate" title={session.title || session.slug}><%= session.slug %></span>
                    </div>

                    <!-- Action Buttons -->
                    <div class="flex items-center space-x-1 ml-2">
                      <%= if session.status in [Status.active(), Status.idle()] do %>
                        <button
                          phx-click="request_opencode_pr"
                          phx-target={@myself}
                          phx-value-id={session.id}
                          class="px-2 py-1 bg-purple-500/20 text-purple-400 hover:bg-purple-500/40 text-xs rounded"
                          title="Request PR creation"
                          aria-label={"Request PR for session " <> session.slug}
                        >
                          PR
                        </button>
                      <% end %>
                      <button
                        phx-click="close_opencode_session"
                        phx-target={@myself}
                        phx-value-id={session.id}
                        class="px-2 py-1 bg-error/20 text-error hover:bg-error/40 text-xs rounded"
                        title="Close session"
                        aria-label={"Close session " <> session.slug}
                      >
                        ✕
                      </button>
                    </div>
                  </div>

                  <!-- Session Title (if different from slug) -->
                  <%= if session.title && session.title != session.slug do %>
                    <div class="text-xs text-base-content/50 truncate mb-1" title={session.title}>
                      <%= session.title %>
                    </div>
                  <% end %>

                  <!-- File Changes -->
                  <%= if session.file_changes.files > 0 do %>
                    <div class="flex items-center space-x-2 text-xs">
                      <span class="text-base-content/40"><%= session.file_changes.files %> files</span>
                      <span class="text-green-400" aria-label={"#{session.file_changes.additions} additions"}>
                        +<%= session.file_changes.additions %>
                      </span>
                      <span class="text-red-400" aria-label={"#{session.file_changes.deletions} deletions"}>
                        -<%= session.file_changes.deletions %>
                      </span>
                    </div>
                  <% end %>

                  <!-- Directory -->
                  <%= if session.directory do %>
                    <div class="text-xs text-base-content/30 truncate mt-1" title={session.directory}>
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
