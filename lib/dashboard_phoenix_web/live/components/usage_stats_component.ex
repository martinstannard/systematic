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
    <div class="panel-data rounded-lg p-3">
      <div class="flex items-center justify-between mb-2">
        <span class="text-[10px] font-mono text-secondary uppercase tracking-wider">📊 Usage</span>
        <button phx-click="refresh_stats" phx-target={@myself} class="text-[10px] text-base-content/40 hover:text-secondary">↻</button>
      </div>
      <div class="grid grid-cols-2 gap-3 text-xs font-mono">
        <div>
          <div class="text-base-content/50 mb-1">OpenCode</div>
          <div class="flex items-center space-x-2">
            <span class="text-white font-bold text-tabular"><%= @usage_stats.opencode[:sessions] || 0 %></span>
            <span class="text-base-content/40">sess</span>
            <span class="text-success text-tabular"><%= @usage_stats.opencode[:total_cost] || "$0" %></span>
          </div>
        </div>
        <div>
          <div class="text-base-content/50 mb-1">Claude</div>
          <div class="flex items-center space-x-2">
            <span class="text-white font-bold text-tabular"><%= @usage_stats.claude[:sessions] || 0 %></span>
            <span class="text-base-content/40">sess</span>
            <span class="text-success text-tabular"><%= @usage_stats.claude[:cost] || "$0" %></span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end