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
    
    # Initialize confirm_issue to nil if not already set
    socket = if Map.has_key?(socket.assigns, :confirm_issue) do
      socket
    else
      assign(socket, confirm_issue: nil)
    end
    
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
  def handle_event("show_work_confirm", %{"id" => issue_id}, socket) do
    case InputValidator.validate_chainlink_issue_id(issue_id) do
      {:ok, validated_issue_id} ->
        # Find the issue to show in the modal
        issue = Enum.find(socket.assigns.chainlink_issues, &(&1.id == validated_issue_id))
        {:noreply, assign(socket, confirm_issue: issue)}
      
      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_work", _, socket) do
    if socket.assigns.confirm_issue do
      issue_id = socket.assigns.confirm_issue.id
      send(self(), {:chainlink_component, :work_on_issue, issue_id})
      {:noreply, assign(socket, confirm_issue: nil)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_confirm", _, socket) do
    {:noreply, assign(socket, confirm_issue: nil)}
  end

  @impl true
  def handle_event("noop", _, socket) do
    # No-op handler to prevent event bubbling to parent elements
    {:noreply, socket}
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
  # CSS handles truncation via overflow-hidden/text-ellipsis - no Elixir truncation needed
  defp format_agent_label(nil), do: "Working"
  defp format_agent_label(label) when is_binary(label) do
    # Try to extract a meaningful suffix after "ticket-NNN-"
    case Regex.run(~r/ticket-\d+-(.+)$/, label) do
      [_, suffix] -> 
        # Clean up and format the suffix (e.g., "chainlink-ux" -> "chainlink ux")
        suffix
        |> String.replace("-", " ")
        |> String.split()
        |> Enum.take(3)
        |> Enum.join(" ")
      _ ->
        # Return the full label - CSS will handle truncation
        label
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
          <!-- Legend: Priority & Status - hidden on mobile for space -->
          <div class="hidden sm:flex items-center justify-between mb-3 text-ui-caption text-base-content/60">
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
                <div class={"flex flex-col sm:flex-row sm:items-center gap-2 sm:space-x-3 px-3 py-3 sm:py-2 rounded border border-base-300 " <> priority_row_class(issue.priority) <> " " <> wip_row_class(work_info)}>
                  <div class="flex items-center gap-2 sm:gap-3">
                    <%= if work_info do %>
                      <!-- Work in progress indicator - replaces Work button -->
                      <div class="flex items-center space-x-1.5 min-w-[70px] max-w-[120px]" role="status" aria-label={"Work in progress by " <> (work_info[:label] || "agent")}>
                        <span class="status-activity-ring text-success flex-shrink-0" aria-hidden="true"></span>
                        <span class="text-ui-caption text-success font-medium truncate" title={work_info[:label] || "Working"}>
                          <%= format_agent_label(work_info[:label]) %>
                        </span>
                      </div>
                    <% else %>
                      <button
                        phx-click="show_work_confirm"
                        phx-value-id={issue.id}
                        phx-target={@myself}
                        class="btn-interactive-sm bg-accent/20 text-accent hover:bg-accent/40 hover:scale-105 active:scale-95 min-w-[70px] min-h-[44px] sm:min-h-0"
                        title="Start work on this issue"
                        aria-label={"Start work on issue #" <> to_string(issue.id)}
                      >
                        <span aria-hidden="true">▶</span>
                        <span>Work</span>
                      </button>
                    <% end %>
                    <span class={status_icon_class(issue.status)} title={status_text(issue.status)} aria-label={status_text(issue.status)}><%= status_icon(issue.status) %></span>
                    <span class="text-ui-value text-accent">#<%= issue.id %></span>
                    <span class={priority_badge(issue.priority) <> " sm:hidden"} title={"Priority: " <> priority_text(issue.priority)}>
                      <%= priority_symbol(issue.priority) %>
                    </span>
                  </div>
                  <span class="text-ui-body truncate flex-1" title={issue.title}><%= issue.title %></span>
                  <span class={"hidden sm:inline " <> priority_badge(issue.priority)} title={"Priority: " <> priority_text(issue.priority)}>
                    <%= priority_symbol(issue.priority) %> <%= priority_text(issue.priority) %>
                  </span>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>

      <!-- Confirmation Modal -->
      <%= if @confirm_issue do %>
        <div
          class="fixed inset-0 bg-gray-900/50 dark:bg-gray-900/80 flex items-center justify-center z-50"
          phx-click="cancel_confirm"
          phx-target={@myself}
          role="dialog"
          aria-modal="true"
          aria-labelledby="chainlink-confirm-title"
          phx-window-keydown="cancel_confirm"
          phx-key="Escape"
        >
          <div
            class="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-lg shadow-xl p-6 max-w-md w-full mx-4"
            phx-click="noop"
            phx-target={@myself}
          >
            <!-- Header -->
            <div class="flex items-center justify-between mb-4">
              <div class="flex items-center space-x-3">
                <span class="text-2xl">🔗</span>
                <h2 id="chainlink-confirm-title" class="text-lg font-bold text-gray-900 dark:text-gray-100">
                  Start Work?
                </h2>
              </div>
              <button
                phx-click="cancel_confirm"
                phx-target={@myself}
                class="text-base-content/60 hover:text-error hover:bg-error/10 p-1 rounded transition-all"
                aria-label="Close modal"
              >
                <span class="text-lg">✕</span>
              </button>
            </div>

            <!-- Issue details -->
            <div class="mb-6 p-4 bg-gray-50 dark:bg-gray-900 rounded-lg border border-gray-200 dark:border-gray-700">
              <div class="flex items-center space-x-2 mb-2">
                <span class="text-ui-value text-accent font-bold">#<%= @confirm_issue.id %></span>
                <span class={priority_badge(@confirm_issue.priority)}>
                  <%= priority_symbol(@confirm_issue.priority) %> <%= priority_text(@confirm_issue.priority) %>
                </span>
              </div>
              <p class="text-ui-body text-gray-800 dark:text-gray-200"><%= @confirm_issue.title %></p>
            </div>

            <!-- Actions -->
            <div class="flex flex-col sm:flex-row items-stretch sm:items-center gap-2 sm:space-x-3">
              <button
                phx-click="cancel_confirm"
                phx-target={@myself}
                class="flex-1 py-3 sm:py-2 px-4 text-ui-label border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 rounded hover:bg-gray-100 dark:hover:bg-gray-700 transition-all min-h-[44px]"
              >
                Cancel
              </button>
              <button
                phx-click="confirm_work"
                phx-target={@myself}
                class="flex-1 py-3 sm:py-2 px-4 text-ui-label bg-accent text-white rounded hover:bg-accent/80 transition-all font-medium min-h-[44px]"
              >
                <span aria-hidden="true">▶</span>
                Start Work
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
