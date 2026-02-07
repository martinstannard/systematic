defmodule DashboardPhoenixWeb.Live.Components.HeaderComponent do
  @moduledoc """
  LiveComponent for displaying the application header with enhanced design.

  Features a modern, polished header with:
  - Clean logo with subtle health indicator
  - Breadcrumb-style navigation context
  - Grouped stats in a pill container
  - Refined theme toggle
  - Responsive mobile/desktop layouts
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header class="header-container" role="banner">
      <div class="header-inner">
        <!-- Left: Brand + Health + Breadcrumb -->
        <div class="header-left">
          <div class="header-brand">
            <a href="/" class="header-logo-link" aria-label="SYSTEMATIC Dashboard Home">
              <h1 class="header-logo">SYSTEMATIC</h1>
            </a>
            <span
              class={health_indicator_class(@health_status)}
              title={health_tooltip(@health_status, @health_last_check)}
              role="status"
              aria-label={"System status: " <> health_status_label(@health_status)}
            >
              <span class="sr-only">{health_text(@health_status)}</span>
            </span>
          </div>
          
    <!-- Breadcrumb (desktop only) -->
          <nav class="header-breadcrumb hidden sm:flex" aria-label="Breadcrumb">
            <span class="breadcrumb-separator" aria-hidden="true">/</span>
            <span class="breadcrumb-current">Dashboard</span>
          </nav>
        </div>
        
    <!-- Right: Stats + Agent Badge + Theme Toggle -->
        <div class="header-right">
          <!-- Stats pill (desktop) -->
          <div class="header-stats" aria-live="polite" aria-label="Dashboard statistics">
            <div class="stat-item">
              <span class="stat-label">Agents</span>
              <span class="stat-value stat-value-success">{@agent_sessions_count}</span>
            </div>
            <div class="stat-divider" aria-hidden="true"></div>
            <div class="stat-item">
              <span class="stat-label">Events</span>
              <span class="stat-value stat-value-primary">{@agent_progress_count}</span>
            </div>
            <%= if @coding_agent_pref == :opencode do %>
              <div class="stat-divider" aria-hidden="true"></div>
              <div class="stat-item">
                <span class="stat-label">ACP</span>
                <%= if @opencode_server_status.running do %>
                  <span
                    class="stat-status stat-status-online"
                    title="OpenCode Server Online"
                    aria-label="Online"
                  >
                    ●
                  </span>
                <% else %>
                  <span
                    class="stat-status stat-status-offline"
                    title="OpenCode Server Offline"
                    aria-label="Offline"
                  >
                    ○
                  </span>
                <% end %>
              </div>
            <% end %>
          </div>
          
    <!-- Mobile: Compact stats -->
          <div class="flex sm:hidden items-center gap-2" aria-live="polite">
            <span class="text-xs font-bold font-mono tabular-nums text-green-500">
              {@agent_sessions_count}
            </span>
            <span class="text-gray-300 dark:text-gray-600">/</span>
            <span class="text-xs font-bold font-mono tabular-nums text-blue-500">
              {@agent_progress_count}
            </span>
          </div>
          
    <!-- Agent Badge -->
          <span
            class={agent_badge_class(@coding_agent_pref)}
            title={"Active coding agent: " <> coding_agent_text(@coding_agent_pref)}
            aria-label={"Active coding agent: " <> coding_agent_text(@coding_agent_pref)}
          >
            <span class="agent-badge-icon" aria-hidden="true">
              {coding_agent_icon(@coding_agent_pref)}
            </span>
            <span class="agent-badge-text">{coding_agent_text(@coding_agent_pref)}</span>
          </span>
          
    <!-- Theme Toggle -->
          <button
            id="theme-toggle"
            phx-hook="ThemeToggle"
            class="header-theme-toggle"
            title="Toggle light/dark mode"
            aria-label="Toggle between light and dark theme"
            aria-pressed="false"
          >
            <svg
              class="sun-icon"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              aria-hidden="true"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M12 3v1m0 16v1m9-9h-1M4 12H3m15.364 6.364l-.707-.707M6.343 6.343l-.707-.707m12.728 0l-.707.707M6.343 17.657l-.707.707M16 12a4 4 0 11-8 0 4 4 0 018 0z"
              />
            </svg>
            <svg
              class="moon-icon"
              style="display: none;"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
              aria-hidden="true"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M20.354 15.354A9 9 0 018.646 3.646 9.003 9.003 0 0012 21a9.003 9.003 0 008.354-5.646z"
              />
            </svg>
          </button>
        </div>
      </div>
    </header>
    """
  end

  # Health indicator classes - using the refined CSS classes
  defp health_indicator_class(:healthy), do: "health-indicator health-indicator-healthy"
  defp health_indicator_class(:unhealthy), do: "health-indicator health-indicator-unhealthy"
  defp health_indicator_class(:checking), do: "health-indicator health-indicator-checking"
  defp health_indicator_class(_), do: "health-indicator health-indicator-unknown"

  # Health status text for accessibility (title case for sr-only)
  defp health_text(:healthy), do: "Healthy"
  defp health_text(:unhealthy), do: "Failed"
  defp health_text(:checking), do: "Checking"
  defp health_text(_), do: "Unknown"

  # Health status label for aria-label (lowercase)
  defp health_status_label(:healthy), do: "healthy"
  defp health_status_label(:unhealthy), do: "failed"
  defp health_status_label(:checking), do: "checking"
  defp health_status_label(_), do: "unknown"

  # Agent badge classes - semantic CSS classes
  defp agent_badge_class(:opencode), do: "agent-badge agent-badge-opencode"
  defp agent_badge_class(:claude), do: "agent-badge agent-badge-claude"
  defp agent_badge_class(:gemini), do: "agent-badge agent-badge-gemini"
  defp agent_badge_class(_), do: "agent-badge agent-badge-unknown"

  # Agent display text
  defp coding_agent_text(:opencode), do: "OpenCode"
  defp coding_agent_text(:claude), do: "Claude"
  defp coding_agent_text(:gemini), do: "Gemini"
  defp coding_agent_text(_), do: "Unknown"

  # Agent icons
  defp coding_agent_icon(:opencode), do: "💻"
  defp coding_agent_icon(:claude), do: "🤖"
  defp coding_agent_icon(:gemini), do: "✨"
  defp coding_agent_icon(_), do: "❓"

  defp health_tooltip(:healthy, last_check) do
    time_ago = format_time_ago(last_check)
    "Healthy — last check #{time_ago}"
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
