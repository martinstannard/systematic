defmodule DashboardPhoenixWeb.Live.Components.WorkRiverComponent do
  @moduledoc """
  Work River - A horizontal "flow" visualization of work moving through stages.

  Shows work items flowing through:
  - **Input** (🔵 Blue): Linear tickets, Chainlink issues awaiting work
  - **In Progress** (🟣 Purple): Active agents working on items
  - **Review** (🟠 Orange): PRs open and awaiting review/merge
  - **Done** (🟢 Green): Recently merged/completed work

  Provides a holistic view of the entire workflow at a glance.
  Click any item to open the unified WorkContextModal with full details.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.Status

  @impl true
  def update(assigns, socket) do
    # Build the river lanes from various data sources
    input_items = build_input_items(assigns)
    in_progress_items = build_in_progress_items(assigns)
    review_items = build_review_items(assigns)
    done_items = build_done_items(assigns)

    # Calculate totals for header
    total_items =
      length(input_items) + length(in_progress_items) + length(review_items) + length(done_items)

    socket =
      socket
      |> assign(assigns)
      |> assign(:input_items, input_items)
      |> assign(:in_progress_items, in_progress_items)
      |> assign(:review_items, review_items)
      |> assign(:done_items, done_items)
      |> assign(:total_items, total_items)

    {:ok, socket}
  end

  # Build input items from Linear tickets and Chainlink issues that don't have work started
  defp build_input_items(assigns) do
    linear_tickets = Map.get(assigns, :linear_tickets, [])
    chainlink_issues = Map.get(assigns, :chainlink_issues, [])
    tickets_in_progress = Map.get(assigns, :tickets_in_progress, %{})
    chainlink_work_in_progress = Map.get(assigns, :chainlink_work_in_progress, %{})

    # Linear tickets not being worked on
    linear_items =
      linear_tickets
      |> Enum.reject(fn ticket ->
        ticket_id = Map.get(ticket, :id) || Map.get(ticket, :identifier)
        Map.has_key?(tickets_in_progress, ticket_id)
      end)
      |> Enum.take(5)
      |> Enum.map(fn ticket ->
        %{
          id: "linear-#{ticket.id || ticket.identifier}",
          type: :linear,
          title: ticket.title,
          identifier: ticket.id || ticket.identifier,
          priority: Map.get(ticket, :priority, "medium"),
          url: Map.get(ticket, :url),
          source_data: ticket
        }
      end)

    # Chainlink issues not being worked on
    chainlink_items =
      chainlink_issues
      |> Enum.reject(fn issue ->
        Map.has_key?(chainlink_work_in_progress, issue.id)
      end)
      |> Enum.take(5)
      |> Enum.map(fn issue ->
        %{
          id: "chainlink-#{issue.id}",
          type: :chainlink,
          title: issue.title,
          identifier: "##{issue.id}",
          priority: issue.priority,
          url: nil,
          source_data: issue
        }
      end)

    linear_items ++ chainlink_items
  end

  # Build in-progress items from active agent sessions
  defp build_in_progress_items(assigns) do
    agent_sessions = Map.get(assigns, :agent_sessions, [])
    opencode_sessions = Map.get(assigns, :opencode_sessions, [])
    _work_registry_entries = Map.get(assigns, :work_registry_entries, [])

    # Active Claude/sub-agent sessions
    claude_items =
      agent_sessions
      |> Enum.filter(fn s -> s.status in [Status.running(), Status.idle()] end)
      |> Enum.reject(fn s -> Map.get(s, :session_key) == "agent:main:main" end)
      |> Enum.take(5)
      |> Enum.map(fn session ->
        %{
          id: "agent-#{session.id}",
          type: :agent,
          agent_type: :claude,
          title: Map.get(session, :task_summary) || Map.get(session, :label) || "Working...",
          identifier: Map.get(session, :label) || String.slice(session.id, 0, 12),
          status: session.status,
          runtime: Map.get(session, :runtime),
          model: Map.get(session, :model),
          session_id: session.id,
          source_data: session
        }
      end)

    # Active OpenCode sessions
    opencode_items =
      opencode_sessions
      |> Enum.filter(fn s -> s.status in [Status.active(), Status.idle()] end)
      |> Enum.take(5)
      |> Enum.map(fn session ->
        %{
          id: "opencode-#{session.id}",
          type: :agent,
          agent_type: :opencode,
          title: session.title || "OpenCode Session",
          identifier: session.slug,
          status: session.status,
          runtime: Map.get(session, :runtime),
          model: Map.get(session, :model),
          session_id: session.id,
          source_data: session
        }
      end)

    claude_items ++ opencode_items
  end

  # Build review items from open PRs
  defp build_review_items(assigns) do
    github_prs = Map.get(assigns, :github_prs, [])
    pr_verifications = Map.get(assigns, :pr_verifications, %{})

    github_prs
    |> Enum.take(5)
    |> Enum.map(fn pr ->
      verification = Map.get(pr_verifications, pr.url)

      %{
        id: "pr-#{pr.number}",
        type: :pr,
        title: pr.title,
        identifier: "##{pr.number}",
        url: pr.url,
        repo: pr.repo,
        branch: pr.branch,
        author: pr.author,
        ci_status: Map.get(pr, :ci_status),
        has_conflicts: Map.get(pr, :has_conflicts, false),
        verification: verification,
        source_data: pr
      }
    end)
  end

  # Build done items from recently merged PRs or completed work
  defp build_done_items(assigns) do
    show_completed = Map.get(assigns, :show_completed, true)
    dismissed_sessions = Map.get(assigns, :dismissed_sessions, MapSet.new())

    if show_completed do
      agent_sessions = Map.get(assigns, :agent_sessions, [])

      # Completed sessions from last 24h, excluding dismissed ones
      agent_sessions
      |> Enum.filter(fn s -> s.status == Status.completed() end)
      |> Enum.reject(fn s -> MapSet.member?(dismissed_sessions, s.id) end)
      |> Enum.take(5)
      |> Enum.map(fn session ->
        %{
          id: "done-#{session.id}",
          type: :completed,
          title: Map.get(session, :task_summary) || Map.get(session, :label) || "Completed",
          identifier: Map.get(session, :label) || String.slice(session.id, 0, 12),
          completed_at: Map.get(session, :updated_at),
          source_data: session
        }
      end)
    else
      []
    end
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:work_river_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("select_item", %{"id" => item_id, "type" => item_type}, socket) do
    # Find the item and open the context modal
    item = find_item(socket.assigns, item_id, item_type)

    if item do
      send(self(), {:work_river_component, :open_context, item})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("start_work", %{"id" => item_id, "type" => item_type}, socket) do
    # Trigger work start action
    send(self(), {:work_river_component, :start_work, {item_id, item_type}})
    {:noreply, socket}
  end

  defp find_item(assigns, item_id, "linear") do
    Enum.find(assigns.input_items, fn i -> i.id == item_id end)
  end

  defp find_item(assigns, item_id, "chainlink") do
    Enum.find(assigns.input_items, fn i -> i.id == item_id end)
  end

  defp find_item(assigns, item_id, "agent") do
    Enum.find(assigns.in_progress_items, fn i -> i.id == item_id end)
  end

  defp find_item(assigns, item_id, "pr") do
    Enum.find(assigns.review_items, fn i -> i.id == item_id end)
  end

  defp find_item(assigns, item_id, "completed") do
    Enum.find(assigns.done_items, fn i -> i.id == item_id end)
  end

  defp find_item(_, _, _), do: nil

  # Priority badge colors
  defp priority_class("urgent"), do: "bg-red-500/20 text-red-400 border-red-500/30"
  defp priority_class("high"), do: "bg-orange-500/20 text-orange-400 border-orange-500/30"
  defp priority_class("medium"), do: "bg-yellow-500/20 text-yellow-400 border-yellow-500/30"
  defp priority_class("low"), do: "bg-green-500/20 text-green-400 border-green-500/30"
  defp priority_class(_), do: "bg-base-content/10 text-base-content/60 border-base-content/20"

  # Agent type icons
  defp agent_icon(:claude), do: "🟣"
  defp agent_icon(:opencode), do: "🔷"
  defp agent_icon(:gemini), do: "✨"
  defp agent_icon(_), do: "⚡"

  # Status indicators
  defp status_class(:running), do: "bg-green-500 animate-pulse"
  defp status_class(:active), do: "bg-green-500 animate-pulse"
  defp status_class(:idle), do: "bg-yellow-500"
  defp status_class(_), do: "bg-gray-500"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="work-river-panel overflow-hidden" id="work-river-panel">
      <div
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
        role="button"
        tabindex="0"
        aria-expanded={if(@work_river_collapsed, do: "false", else: "true")}
        aria-controls="work-river-content"
        aria-label="Toggle Work River panel"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@work_river_collapsed, do: "collapsed", else: "")}>
            ▼
          </span>
          <span class="panel-icon">🌊</span>
          <span class="text-panel-label text-accent font-semibold">Work River</span>
          <span class="text-xs font-mono text-base-content/50">{@total_items} items</span>
        </div>
        
    <!-- Stage counts -->
        <div class="flex items-center gap-4 text-xs">
          <span class="flex items-center gap-1.5 text-blue-400">
            <span class="w-2 h-2 rounded-full bg-blue-500"></span>
            <span class="font-mono">{length(@input_items)}</span>
          </span>
          <span class="flex items-center gap-1.5 text-purple-400">
            <span class="w-2 h-2 rounded-full bg-purple-500 animate-pulse"></span>
            <span class="font-mono">{length(@in_progress_items)}</span>
          </span>
          <span class="flex items-center gap-1.5 text-orange-400">
            <span class="w-2 h-2 rounded-full bg-orange-500"></span>
            <span class="font-mono">{length(@review_items)}</span>
          </span>
          <span class="flex items-center gap-1.5 text-green-400">
            <span class="w-2 h-2 rounded-full bg-green-500"></span>
            <span class="font-mono">{length(@done_items)}</span>
          </span>
        </div>
      </div>

      <div
        id="work-river-content"
        class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@work_river_collapsed, do: "max-h-0", else: "max-h-[600px]")}
      >
        <div class="px-4 pb-4">
          <!-- River Flow Visualization -->
          <div
            class="work-river-flow flex gap-4 overflow-x-auto pb-2"
            role="region"
            aria-label="Work stages"
          >
            
    <!-- INPUT LANE -->
            <div class="work-river-lane flex-shrink-0 w-64" role="region" aria-labelledby="lane-input">
              <div
                id="lane-input"
                class="flex items-center gap-2 mb-3 pb-2 border-b border-blue-500/30"
              >
                <span class="w-3 h-3 rounded-full bg-blue-500"></span>
                <span class="text-sm font-semibold text-blue-400">Input</span>
                <span class="text-xs text-base-content/50 ml-auto">Tickets & Issues</span>
              </div>

              <div class="space-y-2 max-h-[400px] overflow-y-auto">
                <%= if @input_items == [] do %>
                  <div class="text-xs text-base-content/40 text-center py-4 italic">
                    No pending items
                  </div>
                <% else %>
                  <%= for item <- @input_items do %>
                    <div
                      class="river-card bg-blue-500/10 border border-blue-500/20 rounded-lg p-3 cursor-pointer hover:border-blue-500/40 hover:bg-blue-500/15 transition-all"
                      phx-click="select_item"
                      phx-value-id={item.id}
                      phx-value-type={to_string(item.type)}
                      phx-target={@myself}
                      role="button"
                      tabindex="0"
                    >
                      <div class="flex items-start justify-between gap-2 mb-1">
                        <span class="text-xs font-mono text-blue-400">{item.identifier}</span>
                        <span class={"text-xs px-1.5 py-0.5 rounded border " <> priority_class(item.priority)}>
                          {item.priority}
                        </span>
                      </div>
                      <div class="text-sm text-base-content/80 line-clamp-2" title={item.title}>
                        {item.title}
                      </div>
                      <div class="flex items-center justify-between mt-2">
                        <span class={"text-xs " <> if(item.type == :linear, do: "text-blue-400", else: "text-amber-400")}>
                          {if item.type == :linear, do: "Linear", else: "Chainlink"}
                        </span>
                        <button
                          class="text-xs px-2 py-1 bg-blue-500/20 hover:bg-blue-500/30 text-blue-400 rounded transition-colors"
                          phx-click="start_work"
                          phx-value-id={item.id}
                          phx-value-type={to_string(item.type)}
                          phx-target={@myself}
                          onclick="event.stopPropagation()"
                        >
                          Start Work →
                        </button>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
            
    <!-- FLOW ARROW -->
            <div class="flex-shrink-0 flex items-center text-base-content/20">
              <span class="text-2xl">→</span>
            </div>
            
    <!-- IN PROGRESS LANE -->
            <div
              class="work-river-lane flex-shrink-0 w-64"
              role="region"
              aria-labelledby="lane-progress"
            >
              <div
                id="lane-progress"
                class="flex items-center gap-2 mb-3 pb-2 border-b border-purple-500/30"
              >
                <span class="w-3 h-3 rounded-full bg-purple-500 animate-pulse"></span>
                <span class="text-sm font-semibold text-purple-400">In Progress</span>
                <span class="text-xs text-base-content/50 ml-auto">Active Agents</span>
              </div>

              <div class="space-y-2 max-h-[400px] overflow-y-auto">
                <%= if @in_progress_items == [] do %>
                  <div class="text-xs text-base-content/40 text-center py-4 italic">
                    No active work
                  </div>
                <% else %>
                  <%= for item <- @in_progress_items do %>
                    <div
                      class="river-card bg-purple-500/10 border border-purple-500/20 rounded-lg p-3 cursor-pointer hover:border-purple-500/40 hover:bg-purple-500/15 transition-all"
                      phx-click="select_item"
                      phx-value-id={item.id}
                      phx-value-type="agent"
                      phx-target={@myself}
                      role="button"
                      tabindex="0"
                    >
                      <div class="flex items-start justify-between gap-2 mb-1">
                        <div class="flex items-center gap-1.5">
                          <span class={"w-2 h-2 rounded-full " <> status_class(item.status)}></span>
                          <span class="text-xs font-mono text-purple-400">{item.identifier}</span>
                        </div>
                        <span class="text-sm">{agent_icon(item.agent_type)}</span>
                      </div>
                      <div class="text-sm text-base-content/80 line-clamp-2" title={item.title}>
                        {item.title}
                      </div>
                      <div class="flex items-center justify-between mt-2">
                        <%= if item.runtime do %>
                          <span class="text-xs font-mono text-purple-400/70">{item.runtime}</span>
                        <% else %>
                          <span></span>
                        <% end %>
                        <%= if item.status == Status.idle() do %>
                          <span class="text-xs px-2 py-0.5 bg-green-500/20 text-green-400 rounded">
                            Create PR →
                          </span>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
            
    <!-- FLOW ARROW -->
            <div class="flex-shrink-0 flex items-center text-base-content/20">
              <span class="text-2xl">→</span>
            </div>
            
    <!-- REVIEW LANE -->
            <div
              class="work-river-lane flex-shrink-0 w-64"
              role="region"
              aria-labelledby="lane-review"
            >
              <div
                id="lane-review"
                class="flex items-center gap-2 mb-3 pb-2 border-b border-orange-500/30"
              >
                <span class="w-3 h-3 rounded-full bg-orange-500"></span>
                <span class="text-sm font-semibold text-orange-400">Review</span>
                <span class="text-xs text-base-content/50 ml-auto">Open PRs</span>
              </div>

              <div class="space-y-2 max-h-[400px] overflow-y-auto">
                <%= if @review_items == [] do %>
                  <div class="text-xs text-base-content/40 text-center py-4 italic">
                    No PRs in review
                  </div>
                <% else %>
                  <%= for item <- @review_items do %>
                    <div
                      class="river-card bg-orange-500/10 border border-orange-500/20 rounded-lg p-3 cursor-pointer hover:border-orange-500/40 hover:bg-orange-500/15 transition-all"
                      phx-click="select_item"
                      phx-value-id={item.id}
                      phx-value-type="pr"
                      phx-target={@myself}
                      role="button"
                      tabindex="0"
                    >
                      <div class="flex items-start justify-between gap-2 mb-1">
                        <span class="text-xs font-mono text-orange-400">{item.identifier}</span>
                        <div class="flex items-center gap-1">
                          <%= if item.has_conflicts do %>
                            <span
                              class="text-xs px-1 bg-red-500/20 text-red-400 rounded"
                              title="Has merge conflicts"
                            >
                              ⚠️
                            </span>
                          <% end %>
                          <%= if item.ci_status == "failure" do %>
                            <span
                              class="text-xs px-1 bg-red-500/20 text-red-400 rounded"
                              title="CI failing"
                            >
                              ❌
                            </span>
                          <% else %>
                            <%= if item.ci_status == "success" do %>
                              <span
                                class="text-xs px-1 bg-green-500/20 text-green-400 rounded"
                                title="CI passing"
                              >
                                ✅
                              </span>
                            <% end %>
                          <% end %>
                        </div>
                      </div>
                      <div class="text-sm text-base-content/80 line-clamp-2" title={item.title}>
                        {item.title}
                      </div>
                      <div class="flex items-center justify-between mt-2">
                        <span class="text-xs text-base-content/50">{item.author}</span>
                        <%= if item.ci_status == "success" and not item.has_conflicts do %>
                          <span class="text-xs px-2 py-0.5 bg-green-500/20 text-green-400 rounded">
                            Ready to Merge
                          </span>
                        <% end %>
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
            
    <!-- FLOW ARROW -->
            <div class="flex-shrink-0 flex items-center text-base-content/20">
              <span class="text-2xl">→</span>
            </div>
            
    <!-- DONE LANE -->
            <div class="work-river-lane flex-shrink-0 w-64" role="region" aria-labelledby="lane-done">
              <div
                id="lane-done"
                class="flex items-center gap-2 mb-3 pb-2 border-b border-green-500/30"
              >
                <span class="w-3 h-3 rounded-full bg-green-500"></span>
                <span class="text-sm font-semibold text-green-400">Done</span>
                <span class="text-xs text-base-content/50 ml-auto">Recently Completed</span>
              </div>

              <div class="space-y-2 max-h-[400px] overflow-y-auto">
                <%= if @done_items == [] do %>
                  <div class="text-xs text-base-content/40 text-center py-4 italic">
                    No recent completions
                  </div>
                <% else %>
                  <%= for item <- @done_items do %>
                    <div
                      class="river-card bg-green-500/10 border border-green-500/20 rounded-lg p-3 cursor-pointer hover:border-green-500/40 hover:bg-green-500/15 transition-all opacity-80"
                      phx-click="select_item"
                      phx-value-id={item.id}
                      phx-value-type="completed"
                      phx-target={@myself}
                      role="button"
                      tabindex="0"
                    >
                      <div class="flex items-start justify-between gap-2 mb-1">
                        <span class="text-xs font-mono text-green-400">{item.identifier}</span>
                        <span class="text-xs text-green-500">✓</span>
                      </div>
                      <div class="text-sm text-base-content/70 line-clamp-2" title={item.title}>
                        {item.title}
                      </div>
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
          </div>
          
    <!-- Legend / Help text -->
          <div class="mt-4 pt-3 border-t border-base-content/10 text-xs text-base-content/40 text-center">
            Click any card to view full details and available actions
          </div>
        </div>
      </div>
    </div>
    """
  end
end
