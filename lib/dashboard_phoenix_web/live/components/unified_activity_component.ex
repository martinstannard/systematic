defmodule DashboardPhoenixWeb.Live.Components.UnifiedActivityComponent do
  @moduledoc """
  Unified Activity component combining high-level events and granular live feed.

  Provides a hierarchical view of activity with:
  - High-level events (milestones) from ActivityLog as prominent section headers
  - Granular actions (Read/Write/Edit per agent) as collapsible detail
  - Smart auto-collapsing of old sections
  - Streaming support for real-time updates
  - Toggle between milestone-only and full detail view
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       expanded_event: nil,
       detail_level: :recent
     )}
  end

  @impl true
  def update(assigns, socket) do
    assigns = Map.put_new(assigns, :sessions_loading, false)

    socket =
      socket
      |> assign(assigns)
      |> assign_new(:activity_events, fn -> [] end)
      |> assign_new(:progress_events, fn -> [] end)
      |> assign_new(:agent_progress_count, fn -> 0 end)
      |> assign_new(:collapsed, fn -> false end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:unified_activity_component, :toggle_panel})
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
  def handle_event("set_detail_level", %{"level" => level}, socket) do
    level_atom =
      case level do
        "milestones" -> :milestones
        "recent" -> :recent
        "all" -> :all
        _ -> :recent
      end

    {:noreply, assign(socket, detail_level: level_atom)}
  end

  @impl true
  def handle_event("clear_progress", _, socket) do
    send(self(), {:unified_activity_component, :clear_progress})
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_output", %{"ts" => ts_str}, socket) do
    case InputValidator.validate_timestamp_string(ts_str) do
      {:ok, validated_ts} ->
        send(self(), {:unified_activity_component, :toggle_output, validated_ts})
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid timestamp: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-data overflow-hidden mb-3" role="region" aria-label="Unified activity feed">
      <!-- Header -->
      <div class="flex items-center justify-between px-3 py-2">
        <div
          class="panel-header-interactive flex items-center space-x-2 select-none flex-1 py-1 -mx-1 px-1"
          phx-click="toggle_panel"
          phx-target={@myself}
          role="button"
          tabindex="0"
          aria-expanded={if(@collapsed, do: "false", else: "true")}
          aria-controls="unified-activity-content"
          aria-label="Toggle Activity panel"
          onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
        >
          <span
            class={"panel-chevron " <> if(@collapsed, do: "collapsed", else: "")}
            aria-hidden="true"
          >
            ▼
          </span>
          <span class="panel-icon" aria-hidden="true">📊</span>
          <span class="text-panel-label text-secondary">Activity</span>
          <%= if @sessions_loading do %>
            <span class="status-activity-ring text-secondary" aria-hidden="true"></span>
            <span class="sr-only">Loading activity</span>
          <% else %>
            <span
              class="text-xs font-mono text-base-content/50 text-tabular"
              aria-label={"#{length(@activity_events)} milestones, #{@agent_progress_count} actions"}
            >
              {length(@activity_events)} / {@agent_progress_count}
            </span>
          <% end %>
        </div>
        
    <!-- Detail level controls -->
        <div class="flex items-center space-x-1">
          <button
            phx-click="set_detail_level"
            phx-value-level="milestones"
            phx-target={@myself}
            class={"text-xs px-2 py-0.5 rounded transition-colors " <> detail_button_class(@detail_level, :milestones)}
            aria-label="Show milestones only"
            title="Milestones only"
          >
            📌
          </button>
          <button
            phx-click="set_detail_level"
            phx-value-level="recent"
            phx-target={@myself}
            class={"text-xs px-2 py-0.5 rounded transition-colors " <> detail_button_class(@detail_level, :recent)}
            aria-label="Show recent details"
            title="Recent details"
          >
            🔍
          </button>
          <button
            phx-click="set_detail_level"
            phx-value-level="all"
            phx-target={@myself}
            class={"text-xs px-2 py-0.5 rounded transition-colors " <> detail_button_class(@detail_level, :all)}
            aria-label="Show all details"
            title="All details"
          >
            📋
          </button>
          <button
            phx-click="clear_progress"
            phx-target={@myself}
            class="text-xs text-base-content/40 hover:text-secondary px-2 py-1 ml-2"
            aria-label="Clear activity"
          >
            Clear
          </button>
        </div>
      </div>
      
    <!-- Content -->
      <div
        id="unified-activity-content"
        class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@collapsed, do: "max-h-0", else: "max-h-[600px]")}
      >
        <div
          class="px-3 pb-3 overflow-y-auto max-h-[580px] space-y-0.5"
          id="unified-activity-feed"
          role="log"
          aria-live="polite"
          aria-label="Activity log"
        >
          <%= if @sessions_loading do %>
            <div class="flex items-center justify-center py-4 space-x-2">
              <span class="throbber-small"></span>
              <span class="text-ui-caption text-base-content/60">Loading activity...</span>
            </div>
          <% else %>
            <%= if @activity_events == [] and @agent_progress_count == 0 do %>
              <div class="text-xs text-base-content/40 py-4 text-center italic">
                No activity yet
              </div>
            <% else %>
              {render_unified_feed(assigns)}
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # Render the unified feed combining milestones and granular actions
  # Uses a simpler approach: show milestones first, then stream granular below
  defp render_unified_feed(assigns) do
    # Get milestones (high-level events) - take last 20
    milestones = Enum.take(assigns.activity_events, 20)
    assigns = assign(assigns, :milestones, milestones)

    ~H"""
    <%!-- Milestones (high-level events) --%>
    <%= for event <- @milestones do %>
      <.milestone_row
        event={event}
        expanded={@expanded_event == event.id}
        myself={@myself}
      />
    <% end %>

    <%!-- Granular actions (streamed) - only shown based on detail level --%>
    <%= if @detail_level != :milestones do %>
      <div class="ml-4 border-l border-base-content/10 mt-1" id="granular-stream-section">
        <div class="pl-2 py-1 text-[10px] text-base-content/30 uppercase tracking-wider font-semibold">
          Recent Actions
        </div>
        <div id="granular-feed" phx-update="stream">
          <%= for {dom_id, action} <- @progress_events do %>
            <div id={dom_id}>
              <.granular_row action={action} />
            </div>
          <% end %>
        </div>
      </div>
    <% end %>
    """
  end

  # Note: We simplified the timeline approach to use streams directly
  # The milestones are shown first, then granular actions are streamed below

  # Milestone row component (high-level event)
  attr :event, :map, required: true
  attr :expanded, :boolean, default: false
  attr :myself, :any, required: true

  defp milestone_row(assigns) do
    ~H"""
    <div
      class={"py-2 px-2 cursor-pointer transition-colors border-l-2 " <> milestone_border_class(@event.type) <> " " <> event_bg_class(@event.type)}
      phx-click="toggle_expand"
      phx-value-id={@event.id}
      phx-target={@myself}
      role="button"
      tabindex="0"
      aria-expanded={if(@expanded, do: "true", else: "false")}
      aria-label={"#{event_type_label(@event.type)}: #{@event.message}"}
      onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
    >
      <div class="flex items-center space-x-2 text-xs">
        <span class={event_icon_class(@event.type) <> " text-base"}>{event_icon(@event.type)}</span>
        <span class="text-cyan-400/70 w-14 flex-shrink-0 font-mono">
          {format_time(@event.timestamp)}
        </span>
        <span class={event_type_class(@event.type) <> " font-bold w-28 flex-shrink-0"}>
          {event_type_label(@event.type)}
        </span>
        <span class="text-base-content/90 truncate flex-1 font-medium">
          {@event.message}
        </span>
      </div>

      <%= if @expanded and @event.details != %{} do %>
        <div class="mt-2 pl-8 text-xs text-base-content/60 font-mono bg-base-content/5 p-2 rounded">
          <%= for {key, value} <- @event.details do %>
            <div class="flex space-x-2">
              <span class="text-base-content/40">{key}:</span>
              <span class="text-base-content/70">{format_value(value)}</span>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Single granular action row
  attr :action, :map, required: true

  defp granular_row(assigns) do
    ~H"""
    <div class="py-0.5 pl-2 flex items-start space-x-1 text-xs opacity-75 hover:opacity-100 transition-opacity">
      <span class="text-base-content/30 w-12 flex-shrink-0 font-mono">
        {format_granular_time(@action.ts)}
      </span>
      <span class={"flex-shrink-0 px-1 rounded-[2px] text-[9px] uppercase font-bold " <> type_color(Map.get(@action, :agent_type))}>
        {Map.get(@action, :agent_type) || "???"}
      </span>
      <span class={agent_color(@action.agent) <> " w-[140px] flex-shrink-0 truncate text-[10px]"}>
        {@action.agent}
      </span>
      <span class={action_color(@action.action) <> " font-semibold w-8 flex-shrink-0 text-[10px]"}>
        {@action.action}
      </span>
      <span class="text-base-content/50 truncate flex-1 text-[10px]">{@action.target}</span>
    </div>
    """
  end

  # Detail button styling
  defp detail_button_class(current, level) do
    if current == level do
      "bg-secondary/20 text-secondary"
    else
      "text-base-content/40 hover:text-secondary hover:bg-base-content/5"
    end
  end

  # Milestone border colors
  defp milestone_border_class(:code_complete), do: "border-blue-500"
  defp milestone_border_class(:merge_started), do: "border-purple-500"
  defp milestone_border_class(:merge_complete), do: "border-purple-500"
  defp milestone_border_class(:restart_triggered), do: "border-green-500"
  defp milestone_border_class(:restart_complete), do: "border-green-500"
  defp milestone_border_class(:restart_failed), do: "border-red-500"
  defp milestone_border_class(:deploy_complete), do: "border-teal-500"
  defp milestone_border_class(:test_passed), do: "border-emerald-500"
  defp milestone_border_class(:test_failed), do: "border-red-500"
  defp milestone_border_class(:task_started), do: "border-yellow-500"
  defp milestone_border_class(:subagent_started), do: "border-sky-500"
  defp milestone_border_class(:subagent_completed), do: "border-emerald-500"
  defp milestone_border_class(:subagent_failed), do: "border-red-500"
  defp milestone_border_class(:git_commit), do: "border-orange-500"
  defp milestone_border_class(:git_merge), do: "border-purple-500"
  defp milestone_border_class(_), do: "border-base-content/20"

  # Event type icons (from ActivityPanelComponent)
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

  # Event type text colors
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

  # Background colors
  defp event_bg_class(:code_complete), do: "hover:bg-blue-500/10 bg-blue-500/5"
  defp event_bg_class(:merge_started), do: "hover:bg-purple-500/10 bg-purple-500/5"
  defp event_bg_class(:merge_complete), do: "hover:bg-purple-500/10 bg-purple-500/5"
  defp event_bg_class(:restart_triggered), do: "hover:bg-green-500/10 bg-green-500/5"
  defp event_bg_class(:restart_complete), do: "hover:bg-green-500/10 bg-green-500/5"
  defp event_bg_class(:restart_failed), do: "hover:bg-red-500/10 bg-red-500/5"
  defp event_bg_class(:deploy_complete), do: "hover:bg-teal-500/10 bg-teal-500/5"
  defp event_bg_class(:test_passed), do: "hover:bg-emerald-500/10 bg-emerald-500/5"
  defp event_bg_class(:test_failed), do: "hover:bg-red-500/10 bg-red-500/5"
  defp event_bg_class(:task_started), do: "hover:bg-yellow-500/10 bg-yellow-500/5"
  defp event_bg_class(:subagent_started), do: "hover:bg-sky-500/10 bg-sky-500/5"
  defp event_bg_class(:subagent_completed), do: "hover:bg-emerald-500/10 bg-emerald-500/5"
  defp event_bg_class(:subagent_failed), do: "hover:bg-red-500/10 bg-red-500/5"
  defp event_bg_class(:git_commit), do: "hover:bg-orange-500/10 bg-orange-500/5"
  defp event_bg_class(:git_merge), do: "hover:bg-purple-500/10 bg-purple-500/5"
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
    dt
    |> DateTime.add(11 * 3600, :second)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_time(_), do: ""

  # Format granular action timestamp
  defp format_granular_time(nil), do: ""

  defp format_granular_time(ts) when is_integer(ts) do
    ts
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_granular_time(_), do: ""

  # Format detail values
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_number(value), do: to_string(value)
  defp format_value(value) when is_list(value), do: Enum.join(value, ", ")
  defp format_value(value) when is_map(value), do: inspect(value, pretty: true)
  defp format_value(value), do: inspect(value)

  # Agent type colors (from LiveProgressComponent)
  defp type_color("Claude"), do: "bg-orange-500/10 text-orange-400 border border-orange-500/20"
  defp type_color("OpenCode"), do: "bg-blue-500/10 text-blue-400 border border-blue-500/20"

  defp type_color("sub-agent"),
    do: "bg-purple-500/10 text-purple-400 border border-purple-500/20"

  defp type_color(_), do: "bg-base-content/5 text-base-content/40 border border-base-content/10"

  # Agent name colors
  defp agent_color("main"), do: "text-yellow-500 font-semibold"
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

  # Action colors
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
