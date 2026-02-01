defmodule DashboardPhoenixWeb.Live.Components.WorkContextModalComponent do
  @moduledoc """
  Unified Work Context Modal - Shows ALL context for a work item in one place.
  
  When clicking a ticket/work item, this modal aggregates:
  - 📋 Linear/Chainlink ticket status and details
  - 🤖 Active Agent session (with live output if running)
  - 🌿 Branch info
  - 📝 PR status and checks
  
  Provides action buttons to move work forward:
  - "Start Work" on a ticket → spawns agent
  - "Create PR" on an agent card when work done
  - "Merge" on a ready PR
  
  This stops users from hunting across panels for related information.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.Status

  @impl true
  def update(assigns, socket) do
    item = Map.get(assigns, :selected_item)
    
    # Build context based on the item type
    context = if item, do: build_context(item, assigns), else: %{}
    
    socket = socket
    |> assign(assigns)
    |> assign(:context, context)
    
    {:ok, socket}
  end

  # Build unified context for the selected item
  defp build_context(item, assigns) do
    base_context = %{
      item: item,
      ticket: nil,
      agent_session: nil,
      branch: nil,
      pr: nil,
      related_items: []
    }
    
    case item.type do
      :linear -> build_linear_context(base_context, item, assigns)
      :chainlink -> build_chainlink_context(base_context, item, assigns)
      :agent -> build_agent_context(base_context, item, assigns)
      :pr -> build_pr_context(base_context, item, assigns)
      :completed -> build_completed_context(base_context, item, assigns)
      _ -> base_context
    end
  end

  defp build_linear_context(context, item, assigns) do
    tickets_in_progress = Map.get(assigns, :tickets_in_progress, %{})
    ticket_id = item.identifier
    
    # Check if there's active work on this ticket
    work_info = Map.get(tickets_in_progress, ticket_id)
    
    # Find related agent session if work is in progress
    agent_session = if work_info do
      find_agent_session(work_info, assigns)
    end
    
    # Find related PR
    pr = find_related_pr(ticket_id, assigns)
    
    %{context | 
      ticket: item.source_data,
      agent_session: agent_session,
      pr: pr,
      related_items: build_related_items(ticket_id, assigns)
    }
  end

  defp build_chainlink_context(context, item, assigns) do
    chainlink_work_in_progress = Map.get(assigns, :chainlink_work_in_progress, %{})
    issue_id = item.source_data.id
    
    # Check if there's active work
    work_info = Map.get(chainlink_work_in_progress, issue_id)
    
    agent_session = if work_info do
      find_agent_session(work_info, assigns)
    end
    
    %{context | 
      ticket: item.source_data,
      agent_session: agent_session
    }
  end

  defp build_agent_context(context, item, assigns) do
    session = item.source_data
    
    # Extract ticket ID from session label
    ticket_id = extract_ticket_id(session)
    
    # Find the original ticket
    ticket = if ticket_id do
      find_ticket(ticket_id, assigns)
    end
    
    # Find related PR
    pr = if ticket_id, do: find_related_pr(ticket_id, assigns)
    
    %{context | 
      ticket: ticket,
      agent_session: session,
      pr: pr
    }
  end

  defp build_pr_context(context, item, assigns) do
    pr = item.source_data
    
    # Extract ticket ID from PR title or branch
    ticket_id = extract_ticket_from_pr(pr)
    
    # Find the original ticket
    ticket = if ticket_id do
      find_ticket(ticket_id, assigns)
    end
    
    # Find if there's still an agent working
    agent_session = find_agent_for_ticket(ticket_id, assigns)
    
    %{context | 
      ticket: ticket,
      agent_session: agent_session,
      pr: pr,
      branch: pr.branch
    }
  end

  defp build_completed_context(context, item, _assigns) do
    session = item.source_data
    
    %{context | 
      agent_session: session
    }
  end

  # Helper to find agent session from work info
  defp find_agent_session(work_info, assigns) do
    agent_sessions = Map.get(assigns, :agent_sessions, [])
    opencode_sessions = Map.get(assigns, :opencode_sessions, [])
    
    case Map.get(work_info, :type) do
      :opencode ->
        session_id = Map.get(work_info, :session_id)
        Enum.find(opencode_sessions, fn s -> s.id == session_id end)
      
      :subagent ->
        session_id = Map.get(work_info, :session_id)
        Enum.find(agent_sessions, fn s -> s.id == session_id end)
      
      _ ->
        label = Map.get(work_info, :label)
        Enum.find(agent_sessions, fn s -> Map.get(s, :label) == label end)
    end
  end

  defp find_related_pr(ticket_id, assigns) do
    github_prs = Map.get(assigns, :github_prs, [])
    
    Enum.find(github_prs, fn pr ->
      String.contains?(pr.title, ticket_id) or
      String.contains?(pr.branch || "", ticket_id)
    end)
  end

  defp find_ticket(ticket_id, assigns) do
    linear_tickets = Map.get(assigns, :linear_tickets, [])
    
    Enum.find(linear_tickets, fn t ->
      (t.id || t.identifier) == ticket_id
    end)
  end

  defp find_agent_for_ticket(ticket_id, assigns) when is_binary(ticket_id) do
    agent_sessions = Map.get(assigns, :agent_sessions, [])
    
    Enum.find(agent_sessions, fn s ->
      label = Map.get(s, :label, "")
      task = Map.get(s, :task_summary, "")
      s.status in [Status.running(), Status.idle()] and
      (String.contains?(label, ticket_id) or String.contains?(task, ticket_id))
    end)
  end
  defp find_agent_for_ticket(_, _), do: nil

  defp extract_ticket_id(session) do
    label = Map.get(session, :label, "")
    task = Map.get(session, :task_summary, "")
    text = "#{label} #{task}"
    
    case Regex.run(~r/([A-Z]{2,5}-\d+)/i, text) do
      [_, ticket_id] -> String.upcase(ticket_id)
      _ -> nil
    end
  end

  defp extract_ticket_from_pr(pr) do
    text = "#{pr.title} #{pr.branch}"
    
    case Regex.run(~r/([A-Z]{2,5}-\d+)/i, text) do
      [_, ticket_id] -> String.upcase(ticket_id)
      _ -> nil
    end
  end

  defp build_related_items(ticket_id, assigns) do
    # Find all items related to this ticket ID
    agent_sessions = Map.get(assigns, :agent_sessions, [])
    github_prs = Map.get(assigns, :github_prs, [])
    
    related_agents = Enum.filter(agent_sessions, fn s ->
      label = Map.get(s, :label, "")
      task = Map.get(s, :task_summary, "")
      String.contains?(label, ticket_id) or String.contains?(task, ticket_id)
    end)
    
    related_prs = Enum.filter(github_prs, fn pr ->
      String.contains?(pr.title, ticket_id) or
      String.contains?(pr.branch || "", ticket_id)
    end)
    
    Enum.map(related_agents, fn s -> {:agent, s} end) ++
    Enum.map(related_prs, fn pr -> {:pr, pr} end)
  end

  @impl true
  def handle_event("close_modal", _, socket) do
    send(self(), {:work_context_modal, :close})
    {:noreply, socket}
  end

  @impl true
  def handle_event("start_work", _, socket) do
    item = socket.assigns.selected_item
    send(self(), {:work_context_modal, :start_work, item})
    {:noreply, socket}
  end

  @impl true
  def handle_event("create_pr", _, socket) do
    context = socket.assigns.context
    send(self(), {:work_context_modal, :create_pr, context.agent_session})
    {:noreply, socket}
  end

  @impl true
  def handle_event("merge_pr", _, socket) do
    context = socket.assigns.context
    send(self(), {:work_context_modal, :merge_pr, context.pr})
    {:noreply, socket}
  end

  @impl true
  def handle_event("fix_issues", _, socket) do
    context = socket.assigns.context
    send(self(), {:work_context_modal, :fix_issues, context.pr})
    {:noreply, socket}
  end

  # Status badge helpers
  defp status_badge_class(:running), do: "bg-green-500/20 text-green-400"
  defp status_badge_class(:active), do: "bg-green-500/20 text-green-400"
  defp status_badge_class(:idle), do: "bg-yellow-500/20 text-yellow-400"
  defp status_badge_class(:completed), do: "bg-blue-500/20 text-blue-400"
  defp status_badge_class(:failed), do: "bg-red-500/20 text-red-400"
  defp status_badge_class(_), do: "bg-gray-500/20 text-gray-400"

  defp status_text(status) when status in [:running, :active], do: "Running"
  defp status_text(:idle), do: "Idle"
  defp status_text(:completed), do: "Completed"
  defp status_text(:failed), do: "Failed"
  defp status_text(_), do: "Unknown"

  # Agent type icons
  defp agent_icon(:claude), do: "🟣"
  defp agent_icon(:opencode), do: "🔷"
  defp agent_icon(:gemini), do: "✨"
  defp agent_icon(_), do: "⚡"

  @impl true
  def render(assigns) do
    ~H"""
    <div 
      class={"fixed inset-0 bg-gray-900/60 dark:bg-gray-900/80 flex items-center justify-center z-50 " <> if(@show_modal and @selected_item, do: "", else: "hidden")} 
      phx-click="close_modal" 
      phx-target={@myself}
      role="dialog"
      aria-modal="true"
      aria-labelledby="work-context-title"
      phx-window-keydown="close_modal"
      phx-key="Escape"
    >
      <%= if @selected_item && @context do %>
        <div 
          class="bg-base-200 border border-base-300 rounded-lg shadow-2xl w-full max-w-4xl mx-4 max-h-[85vh] overflow-hidden flex flex-col" 
          phx-click-away="close_modal" 
          phx-target={@myself}
          onclick="event.stopPropagation()"
        >
          <!-- Modal Header -->
          <div class="flex items-center justify-between px-6 py-4 border-b border-base-300 bg-base-300/50">
            <div class="flex items-center gap-3">
              <div class={"w-3 h-3 rounded-full " <> item_type_color(@selected_item.type)} aria-hidden="true"></div>
              <h2 id="work-context-title" class="text-xl font-bold text-base-content">
                <%= @selected_item.identifier || @selected_item.title %>
              </h2>
              <span class="text-sm text-base-content/60">
                <%= item_type_label(@selected_item.type) %>
              </span>
            </div>
            <button 
              phx-click="close_modal" 
              phx-target={@myself} 
              class="text-base-content/60 hover:text-error hover:bg-error/10 p-2 rounded transition-all"
              aria-label="Close modal"
            >
              <span class="text-lg">✕</span>
            </button>
          </div>
          
          <!-- Modal Body - Scrollable -->
          <div class="flex-1 overflow-y-auto p-6 space-y-6">
            
            <!-- TICKET/ISSUE SECTION -->
            <%= if @context.ticket || @selected_item.type in [:linear, :chainlink] do %>
              <section class="space-y-3" aria-labelledby="ticket-section">
                <h3 id="ticket-section" class="flex items-center gap-2 text-sm font-semibold text-blue-400">
                  <span class="w-2 h-2 rounded-full bg-blue-500"></span>
                  Ticket Details
                </h3>
                <div class="bg-blue-500/10 border border-blue-500/20 rounded-lg p-4">
                  <div class="flex items-start justify-between mb-3">
                    <div class="flex-1">
                      <h4 class="text-lg font-medium text-base-content">
                        <%= @selected_item.title || (@context.ticket && @context.ticket.title) %>
                      </h4>
                      <div class="flex items-center gap-3 mt-1 text-sm text-base-content/60">
                        <span class="font-mono"><%= @selected_item.identifier %></span>
                        <%= if @selected_item.priority do %>
                          <span class={"px-2 py-0.5 rounded text-xs " <> priority_badge_class(@selected_item.priority)}>
                            <%= @selected_item.priority %>
                          </span>
                        <% end %>
                      </div>
                    </div>
                    <%= if @selected_item.url do %>
                      <a 
                        href={@selected_item.url} 
                        target="_blank"
                        class="px-3 py-1.5 bg-blue-500/20 hover:bg-blue-500/30 text-blue-400 rounded text-sm transition-colors"
                      >
                        Open ↗
                      </a>
                    <% end %>
                  </div>
                  
                  <!-- Description if available -->
                  <%= if @context.ticket && Map.get(@context.ticket, :description) do %>
                    <div class="mt-3 pt-3 border-t border-blue-500/20 text-sm text-base-content/70">
                      <%= @context.ticket.description %>
                    </div>
                  <% end %>
                </div>
              </section>
            <% end %>

            <!-- AGENT SESSION SECTION -->
            <%= if @context.agent_session do %>
              <section class="space-y-3" aria-labelledby="agent-section">
                <h3 id="agent-section" class="flex items-center gap-2 text-sm font-semibold text-purple-400">
                  <span class="w-2 h-2 rounded-full bg-purple-500"></span>
                  Active Agent
                </h3>
                <div class="bg-purple-500/10 border border-purple-500/20 rounded-lg p-4">
                  <div class="flex items-start justify-between mb-3">
                    <div class="flex items-center gap-3">
                      <span class="text-2xl"><%= agent_icon(get_agent_type(@context.agent_session)) %></span>
                      <div>
                        <div class="flex items-center gap-2">
                          <span class="font-medium text-base-content">
                            <%= Map.get(@context.agent_session, :label) || Map.get(@context.agent_session, :slug) %>
                          </span>
                          <span class={"px-2 py-0.5 rounded text-xs " <> status_badge_class(@context.agent_session.status)}>
                            <%= status_text(@context.agent_session.status) %>
                          </span>
                        </div>
                        <%= if Map.get(@context.agent_session, :model) do %>
                          <div class="text-xs text-base-content/50 mt-0.5 font-mono">
                            <%= @context.agent_session.model %>
                          </div>
                        <% end %>
                      </div>
                    </div>
                    <%= if Map.get(@context.agent_session, :runtime) do %>
                      <div class="text-sm font-mono text-purple-400">
                        <%= @context.agent_session.runtime %>
                      </div>
                    <% end %>
                  </div>
                  
                  <!-- Task summary -->
                  <%= if Map.get(@context.agent_session, :task_summary) do %>
                    <div class="bg-purple-500/10 rounded p-3 text-sm text-base-content/80">
                      <%= @context.agent_session.task_summary %>
                    </div>
                  <% end %>
                  
                  <!-- Current action if running -->
                  <%= if @context.agent_session.status in [Status.running(), Status.active()] && Map.get(@context.agent_session, :current_action) do %>
                    <div class="mt-3 pt-3 border-t border-purple-500/20">
                      <div class="text-xs text-purple-400/70 mb-1">▶ Current Action</div>
                      <div class="text-sm font-mono text-green-400 bg-green-500/10 px-3 py-2 rounded">
                        <%= @context.agent_session.current_action %>
                      </div>
                    </div>
                  <% end %>
                  
                  <!-- Token usage if available -->
                  <%= if Map.get(@context.agent_session, :tokens_in, 0) > 0 || Map.get(@context.agent_session, :tokens_out, 0) > 0 do %>
                    <div class="mt-3 pt-3 border-t border-purple-500/20 flex items-center gap-4 text-sm">
                      <div class="flex items-center gap-1 text-base-content/60">
                        <span>↓</span>
                        <span class="font-mono"><%= format_tokens(@context.agent_session.tokens_in) %></span>
                      </div>
                      <div class="flex items-center gap-1 text-base-content/60">
                        <span>↑</span>
                        <span class="font-mono"><%= format_tokens(@context.agent_session.tokens_out) %></span>
                      </div>
                      <%= if Map.get(@context.agent_session, :cost, 0) > 0 do %>
                        <div class="flex items-center gap-1 text-green-400">
                          <span>$</span>
                          <span class="font-mono"><%= Float.round(@context.agent_session.cost, 4) %></span>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </section>
            <% end %>

            <!-- PR SECTION -->
            <%= if @context.pr do %>
              <section class="space-y-3" aria-labelledby="pr-section">
                <h3 id="pr-section" class="flex items-center gap-2 text-sm font-semibold text-orange-400">
                  <span class="w-2 h-2 rounded-full bg-orange-500"></span>
                  Pull Request
                </h3>
                <div class="bg-orange-500/10 border border-orange-500/20 rounded-lg p-4">
                  <div class="flex items-start justify-between mb-3">
                    <div class="flex-1">
                      <h4 class="font-medium text-base-content">
                        <%= @context.pr.title %>
                      </h4>
                      <div class="flex items-center gap-3 mt-1 text-sm text-base-content/60">
                        <span class="font-mono">#<%= @context.pr.number %></span>
                        <span><%= @context.pr.repo %></span>
                        <span>by <%= @context.pr.author %></span>
                      </div>
                    </div>
                    <a 
                      href={@context.pr.url} 
                      target="_blank"
                      class="px-3 py-1.5 bg-orange-500/20 hover:bg-orange-500/30 text-orange-400 rounded text-sm transition-colors"
                    >
                      View PR ↗
                    </a>
                  </div>
                  
                  <!-- PR Status indicators -->
                  <div class="flex items-center gap-3 mt-3">
                    <%= if Map.get(@context.pr, :ci_status) == "success" do %>
                      <span class="flex items-center gap-1.5 px-2 py-1 bg-green-500/20 text-green-400 rounded text-sm">
                        ✅ CI Passing
                      </span>
                    <% else %>
                      <%= if Map.get(@context.pr, :ci_status) == "failure" do %>
                        <span class="flex items-center gap-1.5 px-2 py-1 bg-red-500/20 text-red-400 rounded text-sm">
                          ❌ CI Failing
                        </span>
                      <% end %>
                    <% end %>
                    
                    <%= if Map.get(@context.pr, :has_conflicts) do %>
                      <span class="flex items-center gap-1.5 px-2 py-1 bg-red-500/20 text-red-400 rounded text-sm">
                        ⚠️ Has Conflicts
                      </span>
                    <% else %>
                      <span class="flex items-center gap-1.5 px-2 py-1 bg-green-500/20 text-green-400 rounded text-sm">
                        ✓ No Conflicts
                      </span>
                    <% end %>
                    
                    <%= if Map.get(@context.pr, :reviews_approved, 0) > 0 do %>
                      <span class="flex items-center gap-1.5 px-2 py-1 bg-green-500/20 text-green-400 rounded text-sm">
                        ✓ Approved
                      </span>
                    <% end %>
                  </div>
                  
                  <!-- Branch info -->
                  <%= if @context.pr.branch do %>
                    <div class="mt-3 pt-3 border-t border-orange-500/20 text-sm">
                      <span class="text-base-content/50">Branch:</span>
                      <span class="font-mono text-base-content/80 ml-2"><%= @context.pr.branch %></span>
                    </div>
                  <% end %>
                </div>
              </section>
            <% end %>

            <!-- RELATED ITEMS -->
            <%= if @context.related_items != [] do %>
              <section class="space-y-3" aria-labelledby="related-section">
                <h3 id="related-section" class="flex items-center gap-2 text-sm font-semibold text-base-content/70">
                  <span class="w-2 h-2 rounded-full bg-base-content/30"></span>
                  Related Items
                </h3>
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
                  <%= for {type, item} <- @context.related_items do %>
                    <div class={"p-3 rounded-lg border " <> if(type == :agent, do: "bg-purple-500/5 border-purple-500/20", else: "bg-orange-500/5 border-orange-500/20")}>
                      <div class="flex items-center gap-2 text-sm">
                        <%= if type == :agent do %>
                          <span><%= agent_icon(get_agent_type(item)) %></span>
                          <span class="text-purple-400"><%= Map.get(item, :label) || item.id %></span>
                        <% else %>
                          <span>📝</span>
                          <span class="text-orange-400">#<%= item.number %></span>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                </div>
              </section>
            <% end %>
          </div>
          
          <!-- Modal Footer - Action Buttons -->
          <div class="flex items-center justify-between px-6 py-4 border-t border-base-300 bg-base-300/30">
            <button
              phx-click="close_modal"
              phx-target={@myself}
              class="px-4 py-2 text-base-content/60 hover:text-base-content hover:bg-base-300 rounded transition-colors"
            >
              Close
            </button>
            
            <div class="flex items-center gap-3">
              <!-- Contextual action buttons based on work state -->
              
              <!-- Start Work - shown for tickets without active work -->
              <%= if @selected_item.type in [:linear, :chainlink] && @context.agent_session == nil do %>
                <button
                  phx-click="start_work"
                  phx-target={@myself}
                  class="px-4 py-2 bg-purple-500 hover:bg-purple-600 text-white rounded font-medium transition-colors flex items-center gap-2"
                >
                  🚀 Start Work
                </button>
              <% end %>
              
              <!-- Create PR - shown for idle agents that seem done -->
              <%= if @context.agent_session && @context.agent_session.status == Status.idle() && @context.pr == nil do %>
                <button
                  phx-click="create_pr"
                  phx-target={@myself}
                  class="px-4 py-2 bg-orange-500 hover:bg-orange-600 text-white rounded font-medium transition-colors flex items-center gap-2"
                >
                  📝 Create PR
                </button>
              <% end %>
              
              <!-- Fix Issues - shown for PRs with problems -->
              <%= if @context.pr && (Map.get(@context.pr, :has_conflicts) || Map.get(@context.pr, :ci_status) == "failure") do %>
                <button
                  phx-click="fix_issues"
                  phx-target={@myself}
                  class="px-4 py-2 bg-red-500 hover:bg-red-600 text-white rounded font-medium transition-colors flex items-center gap-2"
                >
                  🔧 Fix Issues
                </button>
              <% end %>
              
              <!-- Merge - shown for PRs that are ready -->
              <%= if @context.pr && Map.get(@context.pr, :ci_status) == "success" && !Map.get(@context.pr, :has_conflicts) do %>
                <button
                  phx-click="merge_pr"
                  phx-target={@myself}
                  class="px-4 py-2 bg-green-500 hover:bg-green-600 text-white rounded font-medium transition-colors flex items-center gap-2"
                >
                  ✓ Merge PR
                </button>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Helper functions

  defp item_type_color(:linear), do: "bg-blue-500"
  defp item_type_color(:chainlink), do: "bg-amber-500"
  defp item_type_color(:agent), do: "bg-purple-500"
  defp item_type_color(:pr), do: "bg-orange-500"
  defp item_type_color(:completed), do: "bg-green-500"
  defp item_type_color(_), do: "bg-gray-500"

  defp item_type_label(:linear), do: "Linear Ticket"
  defp item_type_label(:chainlink), do: "Chainlink Issue"
  defp item_type_label(:agent), do: "Agent Session"
  defp item_type_label(:pr), do: "Pull Request"
  defp item_type_label(:completed), do: "Completed Work"
  defp item_type_label(_), do: "Work Item"

  defp priority_badge_class("urgent"), do: "bg-red-500/20 text-red-400"
  defp priority_badge_class("high"), do: "bg-orange-500/20 text-orange-400"
  defp priority_badge_class("medium"), do: "bg-yellow-500/20 text-yellow-400"
  defp priority_badge_class("low"), do: "bg-green-500/20 text-green-400"
  defp priority_badge_class(_), do: "bg-gray-500/20 text-gray-400"

  defp get_agent_type(session) do
    cond do
      Map.get(session, :slug) -> :opencode
      Map.get(session, :model, "") |> String.contains?("gemini") -> :gemini
      true -> :claude
    end
  end

  defp format_tokens(n) when is_integer(n) and n >= 1_000_000 do
    formatted = Float.round(n / 1_000_000, 1)
    "#{formatted}M"
  end
  defp format_tokens(n) when is_integer(n) and n >= 1_000 do
    formatted = Float.round(n / 1_000, 1)
    "#{formatted}K"
  end
  defp format_tokens(n) when is_integer(n), do: "#{n}"
  defp format_tokens(_), do: "0"
end
