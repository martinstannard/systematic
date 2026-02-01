defmodule DashboardPhoenixWeb.Live.Components.UsageStatsComponent do
  @moduledoc """
  LiveComponent for displaying usage statistics.

  Extracted from HomeLive to improve code organization and maintainability.
  Shows OpenCode and Claude usage stats with session counts and costs.
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
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
    <div class="panel-content-compact">
      <div class="flex items-center justify-between panel-header-compact">
        <span class="text-panel-label text-secondary">📊 Usage</span>
        <button phx-click="refresh_stats" phx-target={@myself} class="text-[10px] text-base-content/40 hover:text-secondary">↻</button>
      </div>
      <div class="grid grid-cols-2 gap-3">
        <div>
          <div class="text-ui-label text-base-content/50 mb-1">OpenCode</div>
          <div class="flex items-center space-x-2">
            <span class="text-ui-value text-white"><%= @usage_stats.opencode[:sessions] || 0 %></span>
            <span class="text-ui-micro text-base-content/40">sess</span>
            <span class="text-ui-value text-success"><%= @usage_stats.opencode[:total_cost] || "$0" %></span>
          </div>
        </div>
        <div>
          <div class="text-ui-label text-base-content/50 mb-1">Claude</div>
          <div class="flex items-center space-x-2">
            <span class="text-ui-value text-white"><%= @usage_stats.claude[:sessions] || 0 %></span>
            <span class="text-ui-micro text-base-content/40">sess</span>
            <span class="text-ui-value text-success"><%= @usage_stats.claude[:cost] || "$0" %></span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end