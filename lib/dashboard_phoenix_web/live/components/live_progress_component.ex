defmodule DashboardPhoenixWeb.Live.Components.LiveProgressComponent do
  @moduledoc """
  LiveView component for displaying real-time progress and activity feed.

  Provides a collapsible panel showing agent activities, progress events,
  and system operations. Supports filtering, output toggling, and clearing
  of progress data with proper input validation.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  def mount(socket) do
    {:ok, socket}
  end

  def update(assigns, socket) do
    assigns = Map.put_new(assigns, :sessions_loading, false)
    socket = assign(socket, assigns)
    {:ok, socket}
  end

  def handle_event("toggle_panel", _, socket) do
    send(self(), {:live_progress_component, :toggle_panel})
    {:noreply, socket}
  end

  def handle_event("clear_progress", _, socket) do
    send(self(), {:live_progress_component, :clear_progress})
    {:noreply, socket}
  end

  def handle_event("toggle_main_entries", _, socket) do
    send(self(), {:live_progress_component, :toggle_main_entries})
    {:noreply, socket}
  end

  def handle_event("set_progress_filter", %{"filter" => filter}, socket) do
    case InputValidator.validate_filter_string(filter) do
      {:ok, validated_filter} ->
        send(self(), {:live_progress_component, :set_progress_filter, validated_filter})
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid filter: #{reason}")
        {:noreply, socket}
    end
  end

  def handle_event("toggle_output", %{"ts" => ts_str}, socket) do
    case InputValidator.validate_timestamp_string(ts_str) do
      {:ok, validated_ts} ->
        send(self(), {:live_progress_component, :toggle_output, validated_ts})
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid timestamp: #{reason}")
        {:noreply, socket}
    end
  end

  def render(assigns) do
    ~H"""
    <div
      class="panel-data overflow-hidden flex-1 min-h-[200px]"
      role="region"
      aria-label="Live progress feed"
    >
      <div class="flex items-center justify-between px-3 py-2">
        <div
          class="panel-header-interactive flex items-center space-x-2 select-none flex-1 py-1 -mx-1 px-1"
          phx-click="toggle_panel"
          phx-target={@myself}
          role="button"
          tabindex="0"
          aria-expanded={if(@live_progress_collapsed, do: "false", else: "true")}
          aria-controls="live-progress-content"
          aria-label="Toggle Live Feed panel"
          onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
        >
          <span
            class={"panel-chevron " <> if(@live_progress_collapsed, do: "collapsed", else: "")}
            aria-hidden="true"
          >
            ▼
          </span>
          <span class="panel-icon" aria-hidden="true">📡</span>
          <span class="text-panel-label text-secondary">Live Feed</span>
          <%= if @sessions_loading do %>
            <span class="status-activity-ring text-secondary" aria-hidden="true"></span>
            <span class="sr-only">Loading live feed</span>
          <% else %>
            <span
              class="text-xs font-mono text-base-content/50 text-tabular"
              aria-label={"#{@agent_progress_count} events"}
            >
              {@agent_progress_count}
            </span>
          <% end %>
        </div>
        <button
          phx-click="clear_progress"
          phx-target={@myself}
          class="text-xs text-base-content/40 hover:text-secondary px-2 py-1"
          aria-label="Clear live feed"
        >
          Clear
        </button>
      </div>

      <div
        id="live-progress-content"
        class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@live_progress_collapsed, do: "max-h-0", else: "max-h-[400px] flex-1")}
      >
        <%= if @sessions_loading do %>
          <div class="flex items-center justify-center py-4 space-x-2">
            <span class="throbber-small"></span>
            <span class="text-ui-caption text-base-content/60">Loading live feed...</span>
          </div>
        <% else %>
          <div
            class="px-3 pb-3 h-full max-h-[350px] overflow-y-auto font-mono text-xs"
            id="progress-feed"
            phx-hook="ScrollBottom"
            phx-update="stream"
            role="log"
            aria-live="polite"
            aria-label="Agent activity log"
          >
            <div
              :for={{dom_id, event} <- @progress_events}
              id={dom_id}
              class="py-0.5 flex items-start space-x-1"
              role="listitem"
            >
              <span class="text-base-content/40 w-12 flex-shrink-0">{format_time(event.ts)}</span>
              <span class={"flex-shrink-0 px-1 rounded-[2px] text-[9px] uppercase font-bold " <> type_color(Map.get(event, :agent_type))}>
                {Map.get(event, :agent_type) || "???"}
              </span>
              <span class={agent_color(event.agent) <> " w-[180px] flex-shrink-0 truncate"}>
                {event.agent}
              </span>
              <span class={action_color(event.action) <> " font-bold w-10 flex-shrink-0"}>
                {event.action}
              </span>
              <span class="text-base-content/70 truncate flex-1">{event.target}</span>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  # Helper functions for styling
  defp format_time(nil), do: ""

  defp format_time(ts) when is_integer(ts) do
    ts
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time(_), do: ""

  defp type_color("Claude"), do: "bg-orange-500/10 text-orange-400 border border-orange-500/20"
  defp type_color("OpenCode"), do: "bg-blue-500/10 text-blue-400 border border-blue-500/20"
  defp type_color("sub-agent"), do: "bg-purple-500/10 text-purple-400 border border-purple-500/20"
  defp type_color(_), do: "bg-base-content/5 text-base-content/40 border border-base-content/10"

  defp agent_color("main"), do: "text-yellow-500 font-semibold"
  # Yellow to indicate "should offload"
  defp agent_color("cron"), do: "text-gray-400"

  defp agent_color(name) when is_binary(name) do
    cond do
      String.contains?(name, "systematic") -> "text-purple-400"
      String.contains?(name, "dashboard") -> "text-purple-400"
      String.contains?(name, "cor-") or String.contains?(name, "fre-") -> "text-orange-400"
      true -> "text-accent"
    end
  end

  defp agent_color(_), do: "text-accent"

  defp action_color("Read"), do: "text-info"
  defp action_color("Edit"), do: "text-warning"
  defp action_color("Write"), do: "text-warning"
  defp action_color("Bash"), do: "text-accent"
  defp action_color("Search"), do: "text-primary"
  defp action_color("Think"), do: "text-secondary"
  defp action_color("Done"), do: "text-success"
  defp action_color("Error"), do: "text-error"
  defp action_color(_), do: "text-base-content/70"
end
