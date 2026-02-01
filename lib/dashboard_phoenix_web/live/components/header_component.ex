defmodule DashboardPhoenixWeb.Live.Components.HeaderComponent do
  @moduledoc """
  LiveComponent for displaying the application header with compact stats.

  Extracted from HomeLive to improve code organization and maintainability.
  Shows the system title, theme toggle, and key dashboard statistics including
  agent counts, events, server status, and current coding agent preference.
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-command rounded-lg px-4 py-2.5 flex items-center justify-between mb-3">
      <div class="flex items-center space-x-4">
        <div class="flex items-center space-x-2">
          <h1 class="text-system-title text-system-glow text-base-content">SYSTEMATIC</h1>
          <span class={health_badge_class(@health_status)} title={health_tooltip(@health_status, @health_last_check)}></span>
        </div>
        <span class="text-system-subtitle text-base-content/70">AGENT CONTROL</span>
        
        <!-- Theme Toggle -->
        <button
          id="theme-toggle"
          phx-hook="ThemeToggle"
          class="p-1.5 rounded-lg bg-base-content/10 hover:bg-base-content/20 transition-colors"
          title="Toggle light/dark mode"
          aria-label="Toggle between light and dark theme"
          aria-pressed="false"
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
      <div class="flex items-center space-x-6" aria-live="polite" aria-label="Dashboard statistics">
        <div class="flex items-center space-x-2">
          <span class="text-ui-label text-base-content/60">Agents:</span>
          <span class="text-ui-value text-tabular text-success"><%= @agent_sessions_count %></span>
        </div>
        <div class="flex items-center space-x-2">
          <span class="text-ui-label text-base-content/60">Events:</span>
          <span class="text-ui-value text-tabular text-primary"><%= @agent_progress_count %></span>
        </div>
        <%= if @coding_agent_pref == :opencode do %>
          <div class="flex items-center space-x-2">
            <span class="text-ui-label text-base-content/60">ACP:</span>
            <%= if @opencode_server_status.running do %>
              <span class="status-beacon text-success"></span>
            <% else %>
              <span class="status-marker-idle text-base-content/30"></span>
            <% end %>
          </div>
        <% end %>
        <div class="flex items-center space-x-1">
          <span class={"px-2 py-0.5 rounded text-ui-caption " <> coding_agent_badge_class(@coding_agent_pref)}>
            <%= coding_agent_badge_text(@coding_agent_pref) %>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions for coding agent styling
  defp coding_agent_badge_class(:opencode), do: "bg-blue-500/20 text-blue-400"
  defp coding_agent_badge_class(:claude), do: "bg-purple-500/20 text-purple-400"
  defp coding_agent_badge_class(:gemini), do: "bg-green-500/20 text-green-400"
  defp coding_agent_badge_class(_), do: "bg-base-content/10 text-base-content/60"

  defp coding_agent_badge_text(:opencode), do: "💻 OpenCode"
  defp coding_agent_badge_text(:claude), do: "🤖 Claude"
  defp coding_agent_badge_text(:gemini), do: "✨ Gemini"
  defp coding_agent_badge_text(_), do: "❓ Unknown"

  # Helper functions for health badge styling
  defp health_badge_class(:healthy), do: "health-badge health-badge-healthy"
  defp health_badge_class(:unhealthy), do: "health-badge health-badge-unhealthy"
  defp health_badge_class(:checking), do: "health-badge health-badge-checking"
  defp health_badge_class(_), do: "health-badge health-badge-unknown"

  defp health_tooltip(:healthy, last_check) do
    time_ago = format_time_ago(last_check)
    "Healthy - last check #{time_ago}"
  end
  defp health_tooltip(:unhealthy, last_check) do
    time_str = format_time(last_check)
    "Health check failed at #{time_str}"
  end
  defp health_tooltip(:checking, _), do: "Checking..."
  defp health_tooltip(_, _), do: "No health data"

  defp format_time_ago(nil), do: "never"
  defp format_time_ago(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(now, datetime)
    
    cond do
      diff_seconds < 60 -> "#{diff_seconds}s ago"
      diff_seconds < 3600 -> "#{div(diff_seconds, 60)}m ago"
      diff_seconds < 86400 -> "#{div(diff_seconds, 3600)}h ago"
      true -> "#{div(diff_seconds, 86400)}d ago"
    end
  end

  defp format_time(nil), do: "unknown"
  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M:%S")
  end
end