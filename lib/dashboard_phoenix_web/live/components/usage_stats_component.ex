defmodule DashboardPhoenixWeb.Live.Components.UsageStatsComponent do
  @moduledoc """
  LiveComponent for displaying usage statistics.

  Extracted from HomeLive to improve code organization and maintainability.
  Shows OpenCode and Claude usage stats with session counts and costs.
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    assigns = Map.put_new(assigns, :stats_loading, false)
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("refresh_stats", _, socket) do
    send(self(), {:usage_stats_component, :refresh_stats})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-content-compact p-4" role="region" aria-label="Usage statistics">
      <div class="flex items-center justify-between panel-header-compact mb-3">
        <span class="text-panel-label text-secondary" aria-hidden="true">📊</span>
        <span class="text-panel-label text-secondary">Usage</span>
        <%= if @stats_loading do %>
          <span class="status-activity-ring text-secondary" aria-hidden="true"></span>
          <span class="sr-only">Loading statistics</span>
        <% else %>
          <button 
            phx-click="refresh_stats" 
            phx-target={@myself} 
            class="btn-interactive-icon !min-w-[32px] !min-h-[32px] text-sm text-base-content/60 hover:text-secondary hover:bg-secondary/10"
            aria-label="Refresh usage statistics"
            title="Refresh"
          >
            <span aria-hidden="true">↻</span>
          </button>
        <% end %>
      </div>
      <%= if @stats_loading do %>
        <div class="flex items-center justify-center py-4 space-x-2">
          <span class="throbber-small"></span>
          <span class="text-ui-caption text-base-content/60">Loading stats...</span>
        </div>
      <% else %>
        <div class="grid grid-cols-2 gap-4" aria-live="polite">
          <div>
            <div class="text-ui-label text-base-content/60 mb-2" id="opencode-stats-label">OpenCode</div>
            <div class="flex items-center space-x-2" aria-labelledby="opencode-stats-label">
              <span class="text-ui-value text-white"><%= @usage_stats.opencode[:sessions] || 0 %></span>
              <span class="text-ui-caption text-base-content/60" aria-label="sessions">sess</span>
              <span class="text-ui-value text-success" aria-label="cost"><%= @usage_stats.opencode[:total_cost] || "$0" %></span>
            </div>
          </div>
          <div>
            <div class="text-ui-label text-base-content/60 mb-2" id="claude-stats-label">Claude</div>
            <div class="flex items-center space-x-2" aria-labelledby="claude-stats-label">
              <span class="text-ui-value text-white"><%= @usage_stats.claude[:sessions] || 0 %></span>
              <span class="text-ui-caption text-base-content/60" aria-label="sessions">sess</span>
              <span class="text-ui-value text-success" aria-label="cost"><%= @usage_stats.claude[:cost] || "$0" %></span>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end