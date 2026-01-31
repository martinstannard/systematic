defmodule DashboardPhoenixWeb.Live.Components.ChainlinkComponent do
  @moduledoc """
  LiveComponent for displaying and interacting with Chainlink issues.

  Shows issues with priority color-coding and a Work button to spawn sub-agents.
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:chainlink_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_chainlink", _, socket) do
    send(self(), {:chainlink_component, :refresh})
    {:noreply, socket}
  end

  @impl true
  def handle_event("work_on_chainlink", %{"id" => issue_id}, socket) do
    send(self(), {:chainlink_component, :work_on_issue, String.to_integer(issue_id)})
    {:noreply, socket}
  end

  # Helper functions

  defp priority_badge(:high), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-[10px]"
  defp priority_badge(:medium), do: "px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-[10px]"
  defp priority_badge(:low), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]"
  defp priority_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  defp priority_row_class(:high), do: "border-l-2 border-red-500/50"
  defp priority_row_class(:medium), do: "border-l-2 border-yellow-500/50"
  defp priority_row_class(:low), do: "border-l-2 border-blue-500/50"
  defp priority_row_class(_), do: ""

  defp wip_row_class(nil), do: "hover:bg-white/5"
  defp wip_row_class(_work_info), do: "bg-accent/10 border-r-2 border-success/50"

  defp status_icon("open"), do: "○"
  defp status_icon("closed"), do: "●"
  defp status_icon(_), do: "◌"

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
          <span class={"text-xs transition-transform duration-200 " <> if(@chainlink_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
          <span class="text-xs font-mono text-accent uppercase tracking-wider">🔗 Chainlink</span>
          <%= if @chainlink_loading do %>
            <span class="throbber-small"></span>
          <% else %>
            <span class="text-[10px] font-mono text-base-content/50"><%= @chainlink_issues_count %></span>
          <% end %>
        </div>
        <button
          phx-click="refresh_chainlink"
          phx-target={@myself}
          class="text-[10px] text-base-content/40 hover:text-accent"
          onclick="event.stopPropagation()"
        >
          ↻
        </button>
      </div>

      <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@chainlink_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-3 pb-3">
          <!-- Priority Legend -->
          <div class="flex items-center space-x-2 mb-2 text-[10px] font-mono text-base-content/50">
            <span class="flex items-center"><span class="w-2 h-2 bg-red-500/50 rounded mr-1"></span>High</span>
            <span class="flex items-center"><span class="w-2 h-2 bg-yellow-500/50 rounded mr-1"></span>Med</span>
            <span class="flex items-center"><span class="w-2 h-2 bg-blue-500/50 rounded mr-1"></span>Low</span>
          </div>

          <!-- Issue List -->
          <div class="space-y-1 max-h-[300px] overflow-y-auto">
            <%= if @chainlink_loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-xs text-base-content/50 font-mono">Loading issues...</span>
              </div>
            <% else %>
              <%= if @chainlink_error do %>
                <div class="text-xs text-error/70 py-2 px-2"><%= @chainlink_error %></div>
              <% end %>
              <%= if Enum.empty?(@chainlink_issues) and is_nil(@chainlink_error) do %>
                <div class="text-xs text-base-content/50 py-2 px-2 font-mono">No open issues</div>
              <% end %>
              <%= for issue <- @chainlink_issues do %>
                <% work_info = Map.get(@chainlink_work_in_progress, issue.id) %>
                <div class={"flex items-center space-x-2 px-2 py-1.5 rounded text-xs font-mono " <> priority_row_class(issue.priority) <> " " <> wip_row_class(work_info)}>
                  <%= if work_info do %>
                    <div class="flex items-center space-x-1" title={"Work in progress: #{work_info[:label]}"}>
                      <span class="w-1.5 h-1.5 bg-success rounded-full animate-pulse"></span>
                      <span class="text-[9px] text-success/70 truncate max-w-[60px]"><%= work_info[:label] || "Working" %></span>
                    </div>
                  <% else %>
                    <button
                      phx-click="work_on_chainlink"
                      phx-value-id={issue.id}
                      phx-target={@myself}
                      class="text-[10px] px-1.5 py-0.5 rounded bg-accent/20 text-accent hover:bg-accent/40"
                      title="Start work on this issue"
                    >
                      ▶
                    </button>
                  <% end %>
                  <span class="text-base-content/40"><%= status_icon(issue.status) %></span>
                  <span class="text-accent">#<%= issue.id %></span>
                  <span class="text-white truncate flex-1" title={issue.title}><%= issue.title %></span>
                  <span class={priority_badge(issue.priority)}><%= issue.priority %></span>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
