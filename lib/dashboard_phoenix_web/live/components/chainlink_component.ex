defmodule DashboardPhoenixWeb.Live.Components.ChainlinkComponent do
  @moduledoc """
  LiveComponent for displaying and interacting with Chainlink issues.

  Shows issues with priority color-coding and a Work button to spawn sub-agents.
  
  Key features:
  - Real-time updates of issue status.
  - Collapsible panel UI.
  - Integration with `InputValidator` for safe issue handling.
  - Persistent work-in-progress tracking.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  @impl true
  def update(assigns, socket) do
    # Pre-calculate empty state to avoid template computation
    issues_empty = Enum.empty?(assigns.chainlink_issues)
    
    assigns_with_computed = Map.put(assigns, :chainlink_issues_empty, issues_empty)
    {:ok, assign(socket, assigns_with_computed)}
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
    case InputValidator.validate_chainlink_issue_id(issue_id) do
      {:ok, validated_issue_id} ->
        send(self(), {:chainlink_component, :work_on_issue, validated_issue_id})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid issue ID: #{reason}")
        {:noreply, socket}
    end
  end

  # Helper functions

  defp priority_badge(:high), do: "px-1.5 py-0.5 bg-red-500/20 text-red-400 dark:text-red-400 text-ui-caption rounded"
  defp priority_badge(:medium), do: "px-1.5 py-0.5 bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 text-ui-caption rounded"
  defp priority_badge(:low), do: "px-1.5 py-0.5 bg-blue-500/20 text-blue-600 dark:text-blue-400 text-ui-caption rounded"
  defp priority_badge(_), do: "px-1.5 py-0.5 bg-base-content/10 text-base-content/60 text-ui-caption rounded"

  defp priority_text(:high), do: "HIGH"
  defp priority_text(:medium), do: "MED"
  defp priority_text(:low), do: "LOW"
  defp priority_text(_), do: "UNKNOWN"

  defp priority_symbol(:high), do: "▲"
  defp priority_symbol(:medium), do: "◆"
  defp priority_symbol(:low), do: "▼"
  defp priority_symbol(_), do: "◌"

  defp priority_row_class(:high), do: "border-l-2 border-l-red-500/50"
  defp priority_row_class(:medium), do: "border-l-2 border-l-yellow-500/50"
  defp priority_row_class(:low), do: "border-l-2 border-l-blue-500/50"
  defp priority_row_class(_), do: ""

  defp wip_row_class(nil), do: "hover:bg-base-300/50 dark:hover:bg-white/5"
  defp wip_row_class(_work_info), do: "bg-success/10 border-r-2 border-r-success/50"

  defp status_icon("open"), do: "○"
  defp status_icon("closed"), do: "●"
  defp status_icon(_), do: "◌"

  defp status_icon_class("open"), do: "text-base-content/60 cursor-help"
  defp status_icon_class("closed"), do: "text-success cursor-help"
  defp status_icon_class(_), do: "text-base-content/60 cursor-help"

  defp status_text("open"), do: "Status: Open"
  defp status_text("closed"), do: "Status: Closed"
  defp status_text(_), do: "Status: Unknown"

  # Format agent label for display - extracts meaningful name from label like "ticket-109-description"
  defp format_agent_label(nil), do: "Working"
  defp format_agent_label(label) when is_binary(label) do
    # Try to extract a meaningful suffix after "ticket-NNN-"
    case Regex.run(~r/ticket-\d+-(.+)$/, label) do
      [_, suffix] -> 
        # Clean up and format the suffix (e.g., "chainlink-ux" -> "chainlink-ux")
        suffix
        |> String.replace("-", " ")
        |> String.split()
        |> Enum.take(3)
        |> Enum.join(" ")
      _ ->
        # Fallback: just use the label, truncated
        if String.length(label) > 20 do
          String.slice(label, 0, 17) <> "..."
        else
          label
        end
    end
  end
  defp format_agent_label(_), do: "Working"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel bg-base-200 border border-base-300 overflow-hidden">
      <div
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
        role="button"
        tabindex="0"
        aria-expanded={if(@chainlink_collapsed, do: "false", else: "true")}
        aria-controls="chainlink-panel-content"
        aria-label="Toggle Chainlink issues panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@chainlink_collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">🔗</span>
          <span class="text-panel-label text-accent">Chainlink</span>
          <%= if @chainlink_loading do %>
            <span class="status-activity-ring text-accent" aria-hidden="true"></span>
            <span class="sr-only">Loading issues</span>
          <% else %>
            <span class="text-ui-caption text-tabular text-base-content/60"><%= @chainlink_issues_count %></span>
          <% end %>
        </div>
        <button
          phx-click="refresh_chainlink"
          phx-target={@myself}
          class="btn-interactive-icon text-base-content/60 hover:text-accent hover:bg-accent/10 !min-h-[32px] !min-w-[32px] !p-1"
          onclick="event.stopPropagation()"
          aria-label="Refresh Chainlink issues"
          title="Refresh issues"
        >
          <span class="text-sm" aria-hidden="true">↻</span>
        </button>
      </div>

      <div id="chainlink-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@chainlink_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-4 pb-4">
          <!-- Legend: Priority & Status -->
          <div class="flex items-center justify-between mb-3 text-ui-caption text-base-content/60">
            <div class="flex items-center space-x-3">
              <span class="flex items-center gap-1 text-red-600 dark:text-red-400"><%= priority_symbol(:high) %> HIGH</span>
              <span class="flex items-center gap-1 text-yellow-600 dark:text-yellow-400"><%= priority_symbol(:medium) %> MED</span>
              <span class="flex items-center gap-1 text-blue-600 dark:text-blue-400"><%= priority_symbol(:low) %> LOW</span>
            </div>
            <div class="flex items-center space-x-3 border-l border-base-300 pl-3">
              <span class="flex items-center gap-1"><span class="text-base-content/60">○</span> Open</span>
              <span class="flex items-center gap-1"><span class="text-success">●</span> Closed</span>
            </div>
          </div>

          <!-- Issue List -->
          <div class="space-y-2 max-h-[300px] overflow-y-auto" role="region" aria-live="polite" aria-label="Chainlink issue list">
            <%= if @chainlink_loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-ui-caption text-base-content/60">Loading issues...</span>
              </div>
            <% else %>
              <%= if @chainlink_error do %>
                <div class="text-ui-caption text-error py-2 px-2"><%= @chainlink_error %></div>
              <% end %>
              <%= if @chainlink_issues_empty and is_nil(@chainlink_error) do %>
                <div class="text-ui-caption text-base-content/60 py-4 text-center">No open issues</div>
              <% end %>
              <%= for issue <- @chainlink_issues do %>
                <% work_info = Map.get(@chainlink_work_in_progress, issue.id) %>
                <div class={"flex items-center space-x-3 px-3 py-2 rounded border border-base-300 " <> priority_row_class(issue.priority) <> " " <> wip_row_class(work_info)}>
                  <%= if work_info do %>
                    <!-- Work in progress indicator - replaces Work button -->
                    <div class="flex items-center space-x-1.5 min-w-[70px]" role="status" aria-label={"Work in progress by " <> (work_info[:label] || "agent")}>
                      <span class="status-activity-ring text-success" aria-hidden="true"></span>
                      <span class="text-ui-caption text-success font-medium" title={work_info[:label] || "Working"}>
                        <%= format_agent_label(work_info[:label]) %>
                      </span>
                    </div>
                  <% else %>
                    <button
                      phx-click="work_on_chainlink"
                      phx-value-id={issue.id}
                      phx-target={@myself}
                      class="btn-interactive-sm bg-accent/20 text-accent hover:bg-accent/40 hover:scale-105 active:scale-95 min-w-[70px]"
                      title="Start work on this issue"
                      aria-label={"Start work on issue #" <> to_string(issue.id)}
                    >
                      <span aria-hidden="true">▶</span>
                      <span>Work</span>
                    </button>
                  <% end %>
                  <span class={status_icon_class(issue.status)} title={status_text(issue.status)} aria-label={status_text(issue.status)}><%= status_icon(issue.status) %></span>
                  <span class="text-ui-value text-accent">#<%= issue.id %></span>
                  <span class="text-ui-body truncate flex-1" title={issue.title}><%= issue.title %></span>
                  <span class={priority_badge(issue.priority)} title={"Priority: " <> priority_text(issue.priority)}>
                    <%= priority_symbol(issue.priority) %> <%= priority_text(issue.priority) %>
                  </span>
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
