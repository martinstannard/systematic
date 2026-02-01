defmodule DashboardPhoenixWeb.Live.Components.WorkModalComponent do
  @moduledoc """
  LiveComponent for the work modal that handles ticket work execution.
  
  This component manages the modal for working on tickets, including:
  - Displaying ticket details
  - Executing work via different coding agents (OpenCode, Claude, Gemini)
  - Handling work state and progress
  
  Extracted from HomeLive to improve code organization and maintainability.
  """
  use DashboardPhoenixWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("close_work_modal", _, socket) do
    send(self(), {:work_modal_component, :close})
    {:noreply, socket}
  end

  @impl true
  def handle_event("execute_work", _, socket) do
    ticket_id = socket.assigns.work_ticket_id
    ticket_details = socket.assigns.work_ticket_details
    coding_pref = socket.assigns.coding_agent_pref
    claude_model = socket.assigns.claude_model
    opencode_model = socket.assigns.opencode_model
    tickets_in_progress = socket.assigns.tickets_in_progress
    
    # Check if work already exists for this ticket
    if Map.has_key?(tickets_in_progress, ticket_id) do
      work_info = Map.get(tickets_in_progress, ticket_id)
      agent_type = if work_info.type == :opencode, do: "OpenCode", else: "sub-agent"
      
      send(self(), {:work_modal_component, :work_already_exists, {ticket_id, agent_type, work_info}})
      {:noreply, socket}
    else
      send(self(), {:work_modal_component, :execute_work, {ticket_id, ticket_details, coding_pref, claude_model, opencode_model}})
      {:noreply, socket}
    end
  end

  # Helper functions

  defp coding_agent_badge_class(:opencode), do: "bg-blue-500/20 text-blue-400"
  defp coding_agent_badge_class(:claude), do: "bg-purple-500/20 text-purple-400"  
  defp coding_agent_badge_class(:gemini), do: "bg-green-500/20 text-green-400"
  defp coding_agent_badge_class(_), do: "bg-base-content/10 text-base-content/60"

  defp coding_agent_badge_text(:opencode), do: "💻 OpenCode"
  defp coding_agent_badge_text(:claude), do: "🤖 Claude"
  defp coding_agent_badge_text(:gemini), do: "✨ Gemini"
  defp coding_agent_badge_text(_), do: "❓ Unknown"

  @impl true
  def render(assigns) do
    ~H"""
    <div class={"fixed inset-0 bg-space flex items-center justify-center z-50 " <> if(@show_work_modal, do: "", else: "hidden")} phx-click="close_work_modal" phx-target={@myself}>
      <!-- Modal panel using agent panel style for distinctive presence -->
      <div class="panel-agent agent-active p-6 max-w-3xl w-full mx-4 max-h-[80vh] overflow-y-auto" phx-click-away="close_work_modal" phx-target={@myself}>
        <!-- Header with enhanced styling -->
        <div class="flex items-center justify-between mb-4">
          <div class="flex items-center space-x-3">
            <div class="status-hex text-accent"></div>
            <h2 class="text-system-title text-accent font-display"><%= @work_ticket_id %></h2>
          </div>
          <button 
            phx-click="close_work_modal" 
            phx-target={@myself} 
            class="btn-interactive-close text-base-content/60 hover:text-error hover:bg-error/10 transition-all"
            aria-label="Close modal"
            title="Close"
          >
            <span class="text-lg" aria-hidden="true">✕</span>
            <span class="sr-only">Close</span>
          </button>
        </div>
        
        <!-- Ticket Details with data panel styling -->
        <div class="mb-6">
          <div class="text-panel-label text-secondary mb-2">Ticket Details</div>
          <%= if @work_ticket_loading do %>
            <div class="flex items-center space-x-2 text-base-content/60" role="status" aria-live="polite">
              <span class="status-activity-ring text-secondary" aria-hidden="true"></span>
              <span class="text-ui-body">Fetching ticket details...</span>
            </div>
          <% else %>
            <!-- Data panel for code display instead of transparent background -->
            <div class="panel-data p-4 max-h-64 overflow-y-auto">
              <pre class="text-ui-value text-base-content/90 whitespace-pre-wrap overflow-x-auto font-mono"><%= @work_ticket_details %></pre>
            </div>
          <% end %>
        </div>
        
        <!-- Execute Work section with distinctive separator -->
        <div class="border-t border-accent/20 pt-4">
          <div class="flex items-center justify-between mb-3">
            <div class="text-panel-label text-primary">Start Working</div>
            <%= if @agent_mode == "round_robin" do %>
              <div class="text-xs font-mono px-3 py-1panel-status bg-warning/20 text-warning">
                <span class="status-beacon text-current" aria-hidden="true"></span>
                <span class="ml-2">🔄 Round Robin → Next: <%= if @last_agent == "claude", do: "OpenCode", else: "Claude" %></span>
              </div>
            <% else %>
              <div class={"text-xs font-mono px-3 py-1panel-status " <> coding_agent_badge_class(@coding_agent_pref)}>
                <span class="status-beacon text-current" aria-hidden="true"></span>
                <span class="ml-2">Using: <%= coding_agent_badge_text(@coding_agent_pref) %></span>
              </div>
            <% end %>
          </div>
          
          <%= if @work_error do %>
            <div class="panel-status bg-error/15 border-error/30 text-error p-3 text-ui-body mb-3" role="alert">
              <span class="status-marker text-error" aria-hidden="true"></span>
              <span class="ml-2"><%= @work_error %></span>
            </div>
          <% end %>
          
          <div class="flex items-center space-x-3">
            <button
              phx-click="execute_work"
              phx-target={@myself}
              disabled={@work_in_progress or @work_ticket_loading or @work_sent}
              class={"flex-1 py-3 text-ui-label font-bold transition-all border " <> 
                cond do
                  @work_sent -> "panel-status bg-success/20 border-success/40 text-success"
                  @work_in_progress -> "panel-status bg-info/20 border-info/40 text-info cursor-wait"
                  true -> "panel-work border-accent/30 text-accent hover:border-accent/60 hover:bg-accent/10"
                end}
              aria-label="Execute work on ticket"
            >
              <%= cond do %>
                <% @work_sent -> %>
                  <span class="status-marker text-success" aria-hidden="true"></span>
                  <span class="ml-2">Work Started</span>
                <% @work_in_progress -> %>
                  <span class="status-activity-ring text-info" aria-hidden="true"></span>
                  <span class="ml-2">Starting...</span>
                <% true -> %>
                  <span class="text-lg" aria-hidden="true">🚀</span>
                  <span class="ml-2">Execute Work</span>
              <% end %>
            </button>
            <a 
              href={"https://linear.app/fresh-clinics/issue/#{@work_ticket_id}"} 
              target="_blank"
              class="px-4 py-3 panel-status text-base-content/70 hover:text-accent transition-colors text-ui-label border border-base-content/20 hover:border-accent/40"
              aria-label="Open ticket in Linear"
            >
              Linear ↗
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end
end