defmodule DashboardPhoenixWeb.Live.Components.LinearComponent do
  @moduledoc """
  LiveComponent for displaying and interacting with Linear tickets.
  
  Extracted from HomeLive to improve code organization and maintainability.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  @impl true
  def update(assigns, socket) do
    # Pre-calculate filtered tickets to avoid template computation
    filtered_tickets = assigns.linear_tickets
    |> Enum.filter(& &1.status == assigns.linear_status_filter)
    |> Enum.take(10)
    
    assigns_with_filtered = Map.put(assigns, :linear_filtered_tickets, filtered_tickets)
    {:ok, assign(socket, assigns_with_filtered)}
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

  defp linear_status_badge("Triaging"), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-xs"
  defp linear_status_badge("Todo"), do: "px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-xs"
  defp linear_status_badge("Backlog"), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-xs"
  defp linear_status_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-xs"

  defp linear_filter_button_active("Triaging"), do: "bg-red-500/30 text-red-400 border border-red-500/50"
  defp linear_filter_button_active("Backlog"), do: "bg-blue-500/30 text-blue-400 border border-blue-500/50"
  defp linear_filter_button_active("Todo"), do: "bg-yellow-500/30 text-yellow-400 border border-yellow-500/50"
  defp linear_filter_button_active("In Review"), do: "bg-purple-500/30 text-purple-400 border border-purple-500/50"
  defp linear_filter_button_active(_), do: "bg-accent/30 text-accent border border-accent/50"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="panel-content-critical">
      <div 
        class="panel-header-critical panel-header-interactive flex items-center justify-between select-none"
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
            <span class="status-activity-ring text-accent"></span>
          <% else %>
            <span class="text-xs font-mono text-base-content/50"><%= length(@linear_tickets) %></span>
          <% end %>
        </div>
        <button 
          phx-click="refresh_linear" 
          phx-target={@myself}
          class="text-xs text-base-content/40 hover:text-accent" 
          onclick="event.stopPropagation()"
          aria-label="Refresh Linear tickets"
        >
          ↻
        </button>
      </div>
      
      <div id="linear-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@linear_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-3 pb-3">
          <!-- Status Filter -->
          <div class="flex items-center space-x-1 mb-2 flex-wrap gap-1">
            <%= for status <- ["Triaging", "Backlog", "Todo", "In Review"] do %>
              <% count = Map.get(@linear_counts, status, 0) %>
              <button
                phx-click="set_linear_filter"
                phx-value-status={status}
                phx-target={@myself}
                class={"px-2 py-0.5 rounded text-xs font-mono transition-all " <> 
                  if(@linear_status_filter == status,
                    do: linear_filter_button_active(status),
                    else: "bg-base-content/10 text-base-content/50 hover:bg-base-content/20"
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
          <div class="space-y-1 max-h-[300px] overflow-y-auto" role="region" aria-live="polite" aria-label="Linear ticket list">
            <%= if @linear_loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-xs text-base-content/50 font-mono">Loading tickets...</span>
              </div>
            <% else %>
              <%= if @linear_error do %>
                <div class="text-xs text-error/70 py-2 px-2"><%= @linear_error %></div>
              <% end %>
              <%= for ticket <- @linear_filtered_tickets do %>
                <% work_info = Map.get(@tickets_in_progress, ticket.id) %>
                <div class={"flex items-center space-x-2 px-2 py-1.5 rounded text-xs font-mono transition-all " <> if(work_info, do: "panel-work bg-accent/15 border border-accent/30", else: "panel-status hover:bg-accent/10 hover:border-accent/30")}>
                  <%= if work_info do %>
                    <span class="w-1.5 h-1.5 bg-success rounded-full animate-pulse"></span>
                  <% else %>
                    <button
                      phx-click="work_on_ticket"
                      phx-value-id={ticket.id}
                      phx-target={@myself}
                      class="text-xs px-1.5 py-0.5 rounded bg-accent/20 text-accent hover:bg-accent/40"
                      aria-label={"Start work on ticket " <> ticket.id}
                      title={"Start work on ticket " <> ticket.id}
                    >
                      ▶
                    </button>
                  <% end %>
                  <a href={ticket.url} target="_blank" class="text-accent hover:underline"><%= ticket.id %></a>
                  <span class="text-white truncate flex-1" title={ticket.title}><%= ticket.title %></span>
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
