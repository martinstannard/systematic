defmodule DashboardPhoenixWeb.Live.Components.PRsComponent do
  @moduledoc """
  LiveComponent for displaying and interacting with GitHub Pull Requests.

  Extracted from HomeLive to improve code organization and maintainability.
  Shows PRs with CI status, review status, conflict badges, and action buttons.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.PRMonitor

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:prs_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_prs", _, socket) do
    send(self(), {:prs_component, :refresh})
    {:noreply, socket}
  end

  @impl true
  def handle_event("fix_pr_issues", params, socket) do
    send(self(), {:prs_component, :fix_pr_issues, params})
    {:noreply, socket}
  end

  @impl true
  def handle_event("verify_pr", params, socket) do
    send(self(), {:prs_component, :verify_pr, params})
    {:noreply, socket}
  end

  @impl true
  def handle_event("clear_pr_verification", params, socket) do
    send(self(), {:prs_component, :clear_verification, params})
    {:noreply, socket}
  end

  @impl true
  def handle_event("request_pr_super_review", params, socket) do
    send(self(), {:prs_component, :super_review, params})
    {:noreply, socket}
  end

  # Helper functions

  # PR CI status badges
  defp pr_ci_badge(:success), do: "px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 text-[10px]"
  defp pr_ci_badge(:failure), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-[10px]"
  defp pr_ci_badge(:pending), do: "px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-[10px] animate-pulse"
  defp pr_ci_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  defp pr_ci_icon(:success), do: "✓"
  defp pr_ci_icon(:failure), do: "✗"
  defp pr_ci_icon(:pending), do: "○"
  defp pr_ci_icon(_), do: "?"

  # PR review status badges
  defp pr_review_badge(:approved), do: "px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 text-[10px]"
  defp pr_review_badge(:changes_requested), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-[10px]"
  defp pr_review_badge(:commented), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]"
  defp pr_review_badge(:pending), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"
  defp pr_review_badge(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  defp pr_review_text(:approved), do: "Approved"
  defp pr_review_text(:changes_requested), do: "Changes"
  defp pr_review_text(:commented), do: "Comments"
  defp pr_review_text(:pending), do: "Pending"
  defp pr_review_text(_), do: "—"

  # PR row background color based on overall status
  defp pr_status_bg(pr) do
    cond do
      pr.ci_status == :failure -> "bg-red-500/10"
      pr.review_status == :changes_requested -> "bg-red-500/10"
      pr.review_status == :approved and pr.ci_status == :success -> "bg-green-500/10"
      pr.has_conflicts -> "bg-yellow-500/10"
      pr.ci_status == :pending -> "bg-yellow-500/10"
      true -> ""
    end
  end

  # Format PR creation time
  defp format_pr_time(nil), do: ""
  defp format_pr_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)
    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end
  defp format_pr_time(_), do: ""

  @impl true
  def render(assigns) do
    ~H"""
    <div class="glass-panel rounded-lg overflow-hidden">
      <div
        class="flex items-center justify-between px-3 py-2 cursor-pointer select-none hover:bg-white/5 transition-colors"
        phx-click="toggle_panel"
        phx-target={@myself}
      >
        <div class="flex items-center space-x-2">
          <span class={"text-xs transition-transform duration-200 " <> if(@prs_collapsed, do: "-rotate-90", else: "rotate-0")}>▼</span>
          <span class="text-xs font-mono text-accent uppercase tracking-wider">🔀 Pull Requests</span>
          <%= if @github_prs_loading do %>
            <span class="throbber-small"></span>
          <% else %>
            <span class="text-[10px] font-mono text-base-content/50"><%= @github_prs_count %></span>
          <% end %>
        </div>
        <button
          phx-click="refresh_prs"
          phx-target={@myself}
          class="text-[10px] text-base-content/40 hover:text-accent"
          onclick="event.stopPropagation()"
        >
          ↻
        </button>
      </div>

      <div class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@prs_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-3 pb-3">
          <!-- PR List -->
          <div class="space-y-2 max-h-[350px] overflow-y-auto">
            <%= if @github_prs_loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-xs text-base-content/50 font-mono">Loading PRs...</span>
              </div>
            <% else %>
              <%= if @github_prs_error do %>
                <div class="text-xs text-error/70 py-2 px-2"><%= @github_prs_error %></div>
              <% end %>
              <%= if @github_prs == [] do %>
                <div class="text-xs text-base-content/50 py-4 text-center font-mono">No open PRs</div>
              <% end %>
              <%= for pr <- @github_prs do %>
                <% pr_work_info = Map.get(@prs_in_progress, pr.number) %>
                <% status_bg = pr_status_bg(pr) %>
                <% verification = Map.get(@pr_verifications, pr.url) %>
                <div class={"px-2 py-2 rounded text-xs font-mono " <>
                  if(pr_work_info,
                    do: "bg-accent/10 border-2 border-accent/50 animate-pulse-subtle",
                    else: "hover:bg-white/5 border border-white/5 #{status_bg}")}>
                  <!-- PR Title and Number -->
                  <div class="flex items-start justify-between mb-1">
                    <div class="flex-1 min-w-0">
                      <a href={pr.url} target="_blank" class="text-white hover:text-accent flex items-center space-x-1">
                        <%= if pr_work_info do %>
                          <span class="w-2 h-2 bg-success rounded-full animate-pulse flex-shrink-0" title={"Agent working: #{pr_work_info[:label] || pr_work_info[:slug]}"}></span>
                        <% end %>
                        <span class="text-accent font-bold">#<%= pr.number %></span>
                        <span class="truncate"><%= pr.title %></span>
                      </a>
                    </div>
                    <!-- Super Review Button -->
                    <button
                      phx-click="request_pr_super_review"
                      phx-target={@myself}
                      phx-value-url={pr.url}
                      phx-value-number={pr.number}
                      phx-value-repo={pr.repo}
                      class="ml-2 px-2 py-0.5 rounded bg-purple-500/20 text-purple-400 hover:bg-purple-500/40 text-[10px] whitespace-nowrap"
                      title="Request Super Review"
                    >
                      🔍 Review
                    </button>
                  </div>

                  <!-- Author and Branch -->
                  <div class="flex items-center space-x-2 text-[10px] text-base-content/50 mb-1.5">
                    <span>by <span class="text-base-content/70"><%= pr.author %></span></span>
                    <span>•</span>
                    <span class="truncate text-blue-400" title={pr.branch}><%= pr.branch %></span>
                    <span>•</span>
                    <span><%= format_pr_time(pr.created_at) %></span>
                  </div>

                  <!-- Status Row: CI, Review, and Tickets -->
                  <div class="flex items-center space-x-2 flex-wrap gap-1">
                    <!-- CI Status -->
                    <span class={pr_ci_badge(pr.ci_status)} title="CI Status">
                      <%= pr_ci_icon(pr.ci_status) %> CI
                    </span>

                    <!-- Conflict Badge -->
                    <%= if pr.has_conflicts do %>
                      <span class="px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-[10px]" title="Has merge conflicts">
                        ⚠️ Conflict
                      </span>
                    <% end %>

                    <!-- Fix Button (for CI failures or conflicts) -->
                    <%= if pr.ci_status == :failure or pr.has_conflicts do %>
                      <% is_fix_pending = @pr_fix_pending == pr.number %>
                      <% is_work_in_progress = pr_work_info != nil %>
                      <% is_disabled = is_fix_pending or is_work_in_progress %>
                      <button
                        phx-click="fix_pr_issues"
                        phx-target={@myself}
                        phx-value-url={pr.url}
                        phx-value-number={pr.number}
                        phx-value-repo={pr.repo}
                        phx-value-branch={pr.branch}
                        phx-value-has-conflicts={pr.has_conflicts}
                        phx-value-ci-failing={pr.ci_status == :failure}
                        disabled={is_disabled}
                        class={[
                          "min-h-[32px] min-w-[44px] px-2 py-1 rounded text-[10px] font-medium",
                          "transition-all duration-150 select-none touch-manipulation",
                          if(is_fix_pending,
                            do: "bg-warning/30 text-warning animate-pulse cursor-wait",
                            else: if(is_work_in_progress,
                              do: "bg-base-content/10 text-base-content/40 cursor-not-allowed",
                              else: "bg-red-500/20 text-red-400 hover:bg-red-500/40 active:bg-red-500/60 active:scale-95"
                            )
                          ),
                          "phx-click-loading:bg-warning/30 phx-click-loading:text-warning phx-click-loading:animate-pulse"
                        ]}
                        title={if is_work_in_progress, do: "Agent already working on this PR", else: "Send to coding agent to fix issues"}
                      >
                        <%= cond do %>
                          <% is_fix_pending -> %>
                            <span class="inline-flex items-center gap-1">
                              <span class="throbber-small"></span>
                              <span>Working...</span>
                            </span>
                          <% is_work_in_progress -> %>
                            🤖 Working
                          <% true -> %>
                            🔧 Fix
                        <% end %>
                      </button>
                    <% end %>

                    <!-- Verification Status Badge -->
                    <%= if verification do %>
                      <span
                        class="px-1.5 py-0.5 rounded bg-green-500/20 text-green-400 text-[10px] inline-flex items-center gap-1"
                        title={"Verified by #{verification["verified_by"]} at #{verification["verified_at"]}"}
                      >
                        ✓ Verified
                        <button
                          phx-click="clear_pr_verification"
                          phx-target={@myself}
                          phx-value-url={pr.url}
                          class="ml-0.5 text-green-400/60 hover:text-red-400"
                          title="Clear verification"
                        >✗</button>
                      </span>
                    <% else %>
                      <button
                        phx-click="verify_pr"
                        phx-target={@myself}
                        phx-value-url={pr.url}
                        phx-value-number={pr.number}
                        phx-value-repo={pr.repo}
                        class="px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/40 hover:bg-green-500/20 hover:text-green-400 text-[10px]"
                        title="Mark as verified"
                      >
                        ○ Verify
                      </button>
                    <% end %>

                    <!-- Review Status -->
                    <span class={pr_review_badge(pr.review_status)} title="Review Status">
                      <%= pr_review_text(pr.review_status) %>
                    </span>

                    <!-- Associated Tickets -->
                    <%= for ticket_id <- pr.ticket_ids do %>
                      <a
                        href={PRMonitor.build_ticket_url(ticket_id)}
                        target="_blank"
                        class="px-1.5 py-0.5 rounded bg-orange-500/20 text-orange-400 hover:bg-orange-500/40 text-[10px]"
                        title="View in Linear"
                      >
                        <%= ticket_id %>
                      </a>
                    <% end %>

                    <!-- Agent Working Indicator -->
                    <%= if pr_work_info do %>
                      <span class="px-1.5 py-0.5 rounded bg-success/20 text-success text-[10px] animate-pulse"
                            title={"#{if pr_work_info.type == :opencode, do: "OpenCode", else: "Sub-agent"} working on this PR"}>
                        🤖 <%= pr_work_info[:label] || pr_work_info[:slug] || "Working..." %>
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>
          </div>

          <!-- Last Updated -->
          <%= if @github_prs_last_updated do %>
            <div class="text-[9px] text-base-content/30 mt-2 text-right font-mono">
              Updated <%= format_pr_time(@github_prs_last_updated) %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
