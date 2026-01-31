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

  alias DashboardPhoenix.{OpenCodeClient, GeminiServer, LinearMonitor}

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
    <div class={"fixed inset-0 bg-black/60 flex items-center justify-center z-50 " <> if(@show_work_modal, do: "", else: "hidden")} phx-click="close_work_modal" phx-target={@myself}>
      <div class="glass-panel rounded-lg p-6 max-w-3xl w-full mx-4 max-h-[80vh] overflow-y-auto" phx-click-away="close_work_modal" phx-target={@myself}>
        <!-- Header -->
        <div class="flex items-center justify-between mb-4">
          <div class="flex items-center space-x-3">
            <span class="text-2xl">🎫</span>
            <h2 class="text-lg font-bold text-white font-mono"><%= @work_ticket_id %></h2>
          </div>
          <button phx-click="close_work_modal" phx-target={@myself} class="text-base-content/60 hover:text-white text-xl">✕</button>
        </div>
        
        <!-- Ticket Details -->
        <div class="mb-6">
          <div class="text-xs font-mono text-accent uppercase tracking-wider mb-2">Ticket Details</div>
          <%= if @work_ticket_loading do %>
            <div class="flex items-center space-x-2 text-base-content/60">
              <span class="throbber"></span>
              <span class="text-sm">Fetching ticket details...</span>
            </div>
          <% else %>
            <pre class="text-xs font-mono text-base-content/80 bg-black/40 rounded-lg p-4 whitespace-pre-wrap overflow-x-auto max-h-64 overflow-y-auto"><%= @work_ticket_details %></pre>
          <% end %>
        </div>
        
        <!-- Execute Work -->
        <div class="border-t border-white/10 pt-4">
          <div class="flex items-center justify-between mb-3">
            <div class="text-xs font-mono text-accent uppercase tracking-wider">Start Working</div>
            <div class={"text-[10px] font-mono px-2 py-1 rounded " <> coding_agent_badge_class(@coding_agent_pref)}>
              Using: <%= coding_agent_badge_text(@coding_agent_pref) %>
            </div>
          </div>
          
          <%= if @work_error do %>
            <div class="bg-error/20 text-error rounded-lg p-3 text-sm font-mono mb-3"><%= @work_error %></div>
          <% end %>
          
          <div class="flex items-center space-x-3">
            <button
              phx-click="execute_work"
              phx-target={@myself}
              disabled={@work_in_progress or @work_ticket_loading or @work_sent}
              class={"flex-1 py-3 rounded-lg text-sm font-mono font-bold transition-all " <> 
                cond do
                  @work_sent -> "bg-green-500/30 text-green-300"
                  @work_in_progress -> "bg-blue-500/30 text-blue-300 cursor-wait"
                  true -> "bg-accent/20 text-accent hover:bg-accent/40"
                end}
            >
              <%= cond do %>
                <% @work_sent -> %>✓ Work Started
                <% @work_in_progress -> %><span class="inline-block animate-spin mr-2">⟳</span> Starting...
                <% true -> %>🚀 Execute Work
              <% end %>
            </button>
            <a 
              href={"https://linear.app/fresh-clinics/issue/#{@work_ticket_id}"} 
              target="_blank"
              class="px-4 py-3 rounded-lg bg-base-content/10 text-base-content/70 hover:bg-base-content/20 text-sm font-mono"
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