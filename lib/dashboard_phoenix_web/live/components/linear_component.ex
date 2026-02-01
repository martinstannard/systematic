defmodule DashboardPhoenixWeb.Live.Components.LinearComponent do
  @moduledoc """
  LiveComponent for displaying and interacting with Linear tickets.
  
  Extracted from HomeLive to improve code organization and maintainability.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  @impl true
  def update(assigns, socket) do
    # Use pre-filtered tickets from HomeLive - no redundant computation needed
    # HomeLive already calculates linear_filtered_tickets and linear_tickets_count
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("set_linear_filter", %{"status" => status}, socket) do
    case InputValidator.validate_filter_string(status) do
      {:ok, validated_status} ->
        send(self(), {:linear_component, :set_filter, validated_status})
        {:noreply, socket}
      
      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid status filter: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:linear_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_linear", _, socket) do
    send(self(), {:linear_component, :refresh})
    {:noreply, socket}
  end

  @impl true
  def handle_event("work_on_ticket", %{"id" => ticket_id}, socket) do
    case InputValidator.validate_linear_ticket_id(ticket_id) do
      {:ok, validated_ticket_id} ->
        send(self(), {:linear_component, :work_on_ticket, validated_ticket_id})
        {:noreply, socket}
      
      {:error, _reason} ->
        # Fall back to general ID validation for tickets that don't follow Linear format
        case InputValidator.validate_general_id(ticket_id) do
          {:ok, validated_ticket_id} ->
            send(self(), {:linear_component, :work_on_ticket, validated_ticket_id})
            {:noreply, socket}
          
          {:error, reason} ->
            socket = put_flash(socket, :error, "Invalid ticket ID: #{reason}")
            {:noreply, socket}
        end
    end
  end

  # Helper functions

  defp linear_filter_button_active("Triaging"), do: "bg-red-500/20 text-red-600 dark:text-red-400 border border-red-500/30"
  defp linear_filter_button_active("Backlog"), do: "bg-blue-500/20 text-blue-600 dark:text-blue-400 border border-blue-500/30"
  defp linear_filter_button_active("Todo"), do: "bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 border border-yellow-500/30"
  defp linear_filter_button_active("In Review"), do: "bg-purple-500/20 text-purple-600 dark:text-purple-400 border border-purple-500/30"
  defp linear_filter_button_active(_), do: "bg-accent/20 text-accent border border-accent/30"

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
        aria-expanded={if(@linear_collapsed, do: "false", else: "true")}
        aria-controls="linear-panel-content"
        aria-label="Toggle Linear tickets panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@linear_collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">🎫</span>
          <span class="text-panel-label text-accent">Linear</span>
          <%= if @linear_loading do %>
            <span class="status-activity-ring text-accent" aria-hidden="true"></span>
            <span class="sr-only">Loading tickets</span>
          <% else %>
            <span class="text-ui-caption text-tabular text-base-content/60"><%= @linear_tickets_count %></span>
          <% end %>
        </div>
        <button 
          phx-click="refresh_linear" 
          phx-target={@myself}
          class="btn-interactive-icon text-base-content/60 hover:text-accent hover:bg-accent/10 !min-h-[32px] !min-w-[32px] !p-1"
          onclick="event.stopPropagation()"
          aria-label="Refresh Linear tickets"
          title="Refresh tickets"
        >
          <span class="text-sm" aria-hidden="true">↻</span>
        </button>
      </div>
      
      <div id="linear-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@linear_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-4 pb-4">
          <!-- Status Filter -->
          <div class="flex items-center space-x-2 mb-3 flex-wrap gap-2">
            <%= for status <- ["Triaging", "Backlog", "Todo", "In Review"] do %>
              <% count = Map.get(@linear_counts, status, 0) %>
              <button
                phx-click="set_linear_filter"
                phx-value-status={status}
                phx-target={@myself}
                class={"px-2.5 py-1 text-ui-caption transition-all rounded " <> 
                  if(@linear_status_filter == status,
                    do: linear_filter_button_active(status),
                    else: "bg-base-content/10 text-base-content/60 hover:bg-base-content/20 border border-transparent"
                  )}
                role="button"
                aria-pressed={if(@linear_status_filter == status, do: "true", else: "false")}
                aria-label={"Filter tickets by #{status} status, #{count} tickets"}
              >
                <%= status %> (<%= count %>)
              </button>
            <% end %>
          </div>
          
          <!-- Ticket List -->
          <div class="space-y-2 max-h-[300px] overflow-y-auto" role="region" aria-live="polite" aria-label="Linear ticket list">
            <%= if @linear_loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-ui-caption text-base-content/60">Loading tickets...</span>
              </div>
            <% else %>
              <%= if @linear_error do %>
                <div class="text-ui-caption text-error py-2 px-2"><%= @linear_error %></div>
              <% end %>
              <%= if @linear_filtered_tickets == [] and is_nil(@linear_error) do %>
                <div class="text-ui-caption text-base-content/60 py-4 text-center">No tickets found</div>
              <% end %>
              <%= for ticket <- @linear_filtered_tickets do %>
                <% work_info = Map.get(@tickets_in_progress, ticket.id) %>
                <div class={"flex items-center space-x-3 px-3 py-2 rounded border transition-all " <> if(work_info, do: "bg-success/10 border-success/30", else: "border-base-300 hover:bg-base-300/50 dark:hover:bg-white/5 hover:border-accent/30")}>
                  <%= if work_info do %>
                    <span class="status-activity-ring text-success" aria-hidden="true"></span>
                    <span class="sr-only">Work in progress</span>
                  <% else %>
                    <button
                      phx-click="work_on_ticket"
                      phx-value-id={ticket.id}
                      phx-target={@myself}
                      class="btn-interactive-sm bg-accent/20 text-accent hover:bg-accent/40 hover:scale-105 active:scale-95"
                      aria-label={"Start work on ticket " <> ticket.id}
                      title={"Start work on ticket " <> ticket.id}
                    >
                      <span aria-hidden="true">▶</span>
                    </button>
                  <% end %>
                  <a href={ticket.url} target="_blank" class="text-ui-value text-accent hover:underline"><%= ticket.id %></a>
                  <span class="text-ui-body truncate flex-1" title={ticket.title}><%= ticket.title %></span>
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
