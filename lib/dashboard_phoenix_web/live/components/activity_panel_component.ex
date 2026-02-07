defmodule DashboardPhoenixWeb.Live.Components.ActivityPanelComponent do
  @moduledoc """
  LiveComponent for displaying recent high-level activity events.

  Shows a compact, always-visible summary of recent events from the
  ActivityLog GenServer, with:
  - Color-coded event types
  - Timestamps
  - Click to expand details
  - Auto-updates via PubSub
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, expanded_event: nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:events, fn -> [] end)
      |> assign_new(:collapsed, fn -> false end)
      |> assign_new(:loading, fn -> false end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:activity_panel_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_expand", %{"id" => event_id}, socket) do
    new_expanded =
      if socket.assigns.expanded_event == event_id do
        nil
      else
        event_id
      end

    {:noreply, assign(socket, expanded_event: new_expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-data overflow-hidden mb-3" role="region" aria-label="Activity log">
      <div class="flex items-center justify-between px-3 py-2">
        <div
          class="panel-header-interactive flex items-center space-x-2 select-none flex-1 py-1 -mx-1 px-1"
          phx-click="toggle_panel"
          phx-target={@myself}
          role="button"
          tabindex="0"
          aria-expanded={if(@collapsed, do: "false", else: "true")}
          aria-controls="activity-panel-content"
          aria-label="Toggle Activity panel"
          onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
        >
          <span
            class={"panel-chevron " <> if(@collapsed, do: "collapsed", else: "")}
            aria-hidden="true"
          >
            ▼
          </span>
          <span class="panel-icon" aria-hidden="true">📋</span>
          <span class="text-panel-label text-secondary">Activity</span>
          <%= if @loading do %>
            <span class="status-activity-ring text-secondary" aria-hidden="true"></span>
            <span class="sr-only">Loading activity events</span>
          <% else %>
            <span
              class="text-xs font-mono text-base-content/50 text-tabular"
              aria-label={"#{length(@events)} events"}
            >
              {length(@events)}
            </span>
          <% end %>
        </div>
      </div>

      <div
        id="activity-panel-content"
        class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@collapsed, do: "max-h-0", else: "max-h-[600px]")}
      >
        <div
          class="px-3 pb-3 overflow-y-auto max-h-[580px] space-y-1"
          id="activity-panel-events"
          role="log"
          aria-live="polite"
          aria-label="Recent activity events"
        >
          <%= if @loading do %>
            <div class="flex items-center justify-center py-4 space-x-2">
              <span class="throbber-small"></span>
              <span class="text-ui-caption text-base-content/60">Loading activity...</span>
            </div>
          <% else %>
            <%= if @events == [] do %>
              <div class="text-xs text-base-content/40 py-2 text-center italic">
                No recent activity
              </div>
            <% else %>
              <%= for event <- Enum.take(@events, 50) do %>
                <div
                  class={"py-1.5 px-2 cursor-pointer transition-colors " <> event_bg_class(event.type)}
                  phx-click="toggle_expand"
                  phx-value-id={event.id}
                  phx-target={@myself}
                  role="button"
                  tabindex="0"
                  aria-expanded={if(@expanded_event == event.id, do: "true", else: "false")}
                  aria-label={"#{event_type_label(event.type)}: #{event.message}. Press Enter to #{if @expanded_event == event.id, do: "collapse", else: "expand"} details."}
                  onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
                >
                  <div class="flex items-center space-x-2 text-xs">
                    <span class={event_icon_class(event.type)}>{event_icon(event.type)}</span>
                    <span class="text-cyan-400/70 w-14 flex-shrink-0 font-mono">
                      {format_time(event.timestamp)}
                    </span>
                    <span class={event_type_class(event.type) <> " font-semibold w-36 flex-shrink-0"}>
                      {event_type_label(event.type)}
                    </span>
                    <span class="text-base-content/90 truncate flex-1">
                      {event.message}
                    </span>
                  </div>

                  <%= if @expanded_event == event.id and event.details != %{} do %>
                    <div class="mt-2 pl-8 text-xs text-base-content/60 font-mono bg-base-content/5 p-2">
                      <%= for {key, value} <- event.details do %>
                        <div class="flex space-x-2">
                          <span class="text-base-content/40">{key}:</span>
                          <span class="text-base-content/70">{format_value(value)}</span>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Event type icons
  defp event_icon(:code_complete), do: "✓"
  defp event_icon(:merge_started), do: "🔀"
  defp event_icon(:merge_complete), do: "✅"
  defp event_icon(:restart_triggered), do: "🔄"
  defp event_icon(:restart_complete), do: "🚀"
  defp event_icon(:restart_failed), do: "❌"
  defp event_icon(:deploy_complete), do: "🚢"
  defp event_icon(:test_passed), do: "✅"
  defp event_icon(:test_failed), do: "❌"
  defp event_icon(:task_started), do: "▶️"
  defp event_icon(:subagent_started), do: "🤖"
  defp event_icon(:subagent_completed), do: "✅"
  defp event_icon(:subagent_failed), do: "💥"
  defp event_icon(:git_commit), do: "📝"
  defp event_icon(:git_merge), do: "🔀"
  defp event_icon(_), do: "•"

  # Event type text colors - matching the ticket spec
  # code complete = blue, merge = purple, restart = green
  defp event_type_class(:code_complete), do: "text-blue-400"
  defp event_type_class(:merge_started), do: "text-purple-400"
  defp event_type_class(:merge_complete), do: "text-purple-400"
  defp event_type_class(:restart_triggered), do: "text-green-400"
  defp event_type_class(:restart_complete), do: "text-green-400"
  defp event_type_class(:restart_failed), do: "text-red-400"
  defp event_type_class(:deploy_complete), do: "text-teal-400"
  defp event_type_class(:test_passed), do: "text-emerald-400"
  defp event_type_class(:test_failed), do: "text-red-400"
  defp event_type_class(:task_started), do: "text-yellow-400"
  defp event_type_class(:subagent_started), do: "text-sky-400"
  defp event_type_class(:subagent_completed), do: "text-emerald-400"
  defp event_type_class(:subagent_failed), do: "text-red-400"
  defp event_type_class(:git_commit), do: "text-orange-400"
  defp event_type_class(:git_merge), do: "text-purple-400"
  defp event_type_class(_), do: "text-base-content/60"

  # Icon colors
  defp event_icon_class(:code_complete), do: "text-blue-400"
  defp event_icon_class(:merge_started), do: "text-purple-400"
  defp event_icon_class(:merge_complete), do: "text-purple-400"
  defp event_icon_class(:restart_triggered), do: "text-green-400"
  defp event_icon_class(:restart_complete), do: "text-green-400"
  defp event_icon_class(:restart_failed), do: "text-red-400"
  defp event_icon_class(:deploy_complete), do: "text-teal-400"
  defp event_icon_class(:test_passed), do: "text-emerald-400"
  defp event_icon_class(:test_failed), do: "text-red-400"
  defp event_icon_class(:task_started), do: "text-yellow-400"
  defp event_icon_class(:subagent_started), do: "text-sky-400"
  defp event_icon_class(:subagent_completed), do: "text-emerald-400"
  defp event_icon_class(:subagent_failed), do: "text-red-400"
  defp event_icon_class(:git_commit), do: "text-orange-400"
  defp event_icon_class(:git_merge), do: "text-purple-400"
  defp event_icon_class(_), do: "text-base-content/40"

  # Background colors on hover/for visual distinction
  defp event_bg_class(:code_complete), do: "hover:bg-blue-500/10"
  defp event_bg_class(:merge_started), do: "hover:bg-purple-500/10"
  defp event_bg_class(:merge_complete), do: "hover:bg-purple-500/10"
  defp event_bg_class(:restart_triggered), do: "hover:bg-green-500/10"
  defp event_bg_class(:restart_complete), do: "hover:bg-green-500/10"
  defp event_bg_class(:restart_failed), do: "hover:bg-red-500/10"
  defp event_bg_class(:deploy_complete), do: "hover:bg-teal-500/10"
  defp event_bg_class(:test_passed), do: "hover:bg-emerald-500/10"
  defp event_bg_class(:test_failed), do: "hover:bg-red-500/10"
  defp event_bg_class(:task_started), do: "hover:bg-yellow-500/10"
  defp event_bg_class(:subagent_started), do: "hover:bg-sky-500/10"
  defp event_bg_class(:subagent_completed), do: "hover:bg-emerald-500/10"
  defp event_bg_class(:subagent_failed), do: "hover:bg-red-500/10"
  defp event_bg_class(:git_commit), do: "hover:bg-orange-500/10"
  defp event_bg_class(:git_merge), do: "hover:bg-purple-500/10"
  defp event_bg_class(_), do: "hover:bg-base-content/5"

  # Human-readable event type labels
  defp event_type_label(:code_complete), do: "Code Complete"
  defp event_type_label(:merge_started), do: "Merge Started"
  defp event_type_label(:merge_complete), do: "Merge Complete"
  defp event_type_label(:restart_triggered), do: "Restart"
  defp event_type_label(:restart_complete), do: "Restart Done"
  defp event_type_label(:restart_failed), do: "Restart Failed"
  defp event_type_label(:deploy_complete), do: "Deployed"
  defp event_type_label(:test_passed), do: "Tests Passed"
  defp event_type_label(:test_failed), do: "Tests Failed"
  defp event_type_label(:task_started), do: "Task Started"
  defp event_type_label(:subagent_started), do: "Sub-agent Started"
  defp event_type_label(:subagent_completed), do: "Sub-agent Done"
  defp event_type_label(:subagent_failed), do: "Sub-agent Failed"
  defp event_type_label(:git_commit), do: "Git Commit"
  defp event_type_label(:git_merge), do: "Git Merge"

  defp event_type_label(type),
    do: type |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  # Format timestamp in Sydney time (UTC+11)
  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt) do
    # Add 11 hours for AEDT (Sydney summer time)
    dt
    |> DateTime.add(11 * 3600, :second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time(_), do: ""

  # Format detail values
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_value(value) when is_map(value), do: inspect(value, pretty: true)
  defp format_value(value), do: inspect(value)
end
