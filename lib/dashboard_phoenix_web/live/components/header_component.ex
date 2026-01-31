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
    <div class="glass-panel rounded-lg px-4 py-2 flex items-center justify-between mb-3">
      <div class="flex items-center space-x-4">
        <h1 class="text-sm font-bold tracking-widest text-base-content">SYSTEMATIC</h1>
        <span class="text-[10px] text-base-content/60 font-mono">AGENT CONTROL</span>
        
        <!-- Theme Toggle -->
        <button
          id="theme-toggle"
          phx-hook="ThemeToggle"
          class="p-1.5 rounded-lg bg-base-content/10 hover:bg-base-content/20 transition-colors"
          title="Toggle light/dark mode"
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
      <div class="flex items-center space-x-6 text-xs font-mono">
        <div class="flex items-center space-x-2">
          <span class="text-base-content/50">Agents:</span>
          <span class="text-success font-bold"><%= @agent_sessions_count %></span>
        </div>
        <div class="flex items-center space-x-2">
          <span class="text-base-content/50">Events:</span>
          <span class="text-primary font-bold"><%= @agent_progress_count %></span>
        </div>
        <%= if @coding_agent_pref == :opencode do %>
          <div class="flex items-center space-x-2">
            <span class="text-base-content/50">ACP:</span>
            <%= if @opencode_server_status.running do %>
              <span class="w-2 h-2 rounded-full bg-success animate-pulse"></span>
            <% else %>
              <span class="w-2 h-2 rounded-full bg-base-content/30"></span>
            <% end %>
          </div>
        <% end %>
        <div class="flex items-center space-x-1">
          <span class={"px-2 py-0.5 rounded text-[10px] " <> coding_agent_badge_class(@coding_agent_pref)}>
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
end