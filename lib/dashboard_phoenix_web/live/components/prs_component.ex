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

  # PR CI status badges - consistent spacing and dark/light mode support
  defp pr_ci_badge(:success), do: "px-1.5 py-0.5 bg-green-500/20 text-green-600 dark:text-green-400 text-ui-caption rounded"
  defp pr_ci_badge(:failure), do: "px-1.5 py-0.5 bg-red-500/20 text-red-600 dark:text-red-400 text-ui-caption rounded"
  defp pr_ci_badge(:pending), do: "px-1.5 py-0.5 bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 text-ui-caption rounded"
  defp pr_ci_badge(_), do: "px-1.5 py-0.5 bg-base-content/10 text-base-content/60 text-ui-caption rounded"

  defp pr_ci_icon(:success), do: "✓"
  defp pr_ci_icon(:failure), do: "✗"
  defp pr_ci_icon(:pending), do: "○"
  defp pr_ci_icon(_), do: "?"

  defp pr_ci_text(:success), do: "Passed"
  defp pr_ci_text(:failure), do: "Failed"
  defp pr_ci_text(:pending), do: "Pending"
  defp pr_ci_text(_), do: "Unknown"

  # PR review status badges - consistent styling
  defp pr_review_badge(:approved), do: "px-1.5 py-0.5 bg-green-500/20 text-green-600 dark:text-green-400 text-ui-caption rounded"
  defp pr_review_badge(:changes_requested), do: "px-1.5 py-0.5 bg-red-500/20 text-red-600 dark:text-red-400 text-ui-caption rounded"
  defp pr_review_badge(:commented), do: "px-1.5 py-0.5 bg-blue-500/20 text-blue-600 dark:text-blue-400 text-ui-caption rounded"
  defp pr_review_badge(:pending), do: "px-1.5 py-0.5 bg-base-content/10 text-base-content/60 text-ui-caption rounded"
  defp pr_review_badge(_), do: "px-1.5 py-0.5 bg-base-content/10 text-base-content/60 text-ui-caption rounded"

  defp pr_review_text(:approved), do: "Approved"
  defp pr_review_text(:changes_requested), do: "Changes"
  defp pr_review_text(:commented), do: "Comments"
  defp pr_review_text(:pending), do: "Pending"
  defp pr_review_text(_), do: "—"

  # PR row left border color based on overall status - subtle indicator
  defp pr_status_border(pr) do
    cond do
      pr.ci_status == :failure -> "border-l-2 border-l-red-500/50"
      pr.review_status == :changes_requested -> "border-l-2 border-l-red-500/50"
      pr.review_status == :approved and pr.ci_status == :success -> "border-l-2 border-l-green-500/50"
      pr.has_conflicts -> "border-l-2 border-l-yellow-500/50"
      pr.ci_status == :pending -> "border-l-2 border-l-yellow-500/50"
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
    <div class="panel bg-base-200 border border-base-300 overflow-hidden">
      <div
        class="panel-header-interactive flex items-center justify-between px-3 py-2 select-none"
        phx-click="toggle_panel"
        phx-target={@myself}
        role="button"
        tabindex="0"
        aria-expanded={if(@prs_collapsed, do: "false", else: "true")}
        aria-controls="prs-panel-content"
        aria-label="Toggle Pull Requests panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@prs_collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">🔀</span>
          <span class="text-panel-label text-accent">Pull Requests</span>
          <%= if @github_prs_loading do %>
            <span class="status-activity-ring text-accent" aria-hidden="true"></span>
            <span class="sr-only">Loading pull requests</span>
          <% else %>
            <span class="text-ui-caption text-tabular text-base-content/60"><%= @github_prs_count %></span>
          <% end %>
        </div>
        <button
          phx-click="refresh_prs"
          phx-target={@myself}
          class="btn-interactive-icon text-base-content/60 hover:text-accent hover:bg-accent/10 !min-h-[32px] !min-w-[32px] !p-1"
          onclick="event.stopPropagation()"
          aria-label="Refresh Pull Requests"
          title="Refresh PRs"
        >
          <span class="text-sm" aria-hidden="true">↻</span>
        </button>
      </div>

      <div id="prs-panel-content" class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@prs_collapsed, do: "max-h-0", else: "max-h-[400px]")}>
        <div class="px-4 pb-4">
          <!-- PR List -->
          <div class="space-y-2 max-h-[350px] overflow-y-auto" role="region" aria-live="polite" aria-label="Pull requests list">
            <%= if @github_prs_loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-ui-caption text-base-content/60">Loading PRs...</span>
              </div>
            <% else %>
              <%= if @github_prs_error do %>
                <div class="text-ui-caption text-error py-2 px-2"><%= @github_prs_error %></div>
              <% end %>
              <%= if @github_prs == [] do %>
                <div class="text-ui-caption text-base-content/60 py-4 text-center">No open PRs</div>
              <% end %>
              <%= for pr <- @github_prs do %>
                <% pr_work_info = Map.get(@prs_in_progress, pr.number) %>
                <% status_border = pr_status_border(pr) %>
                <% verification = Map.get(@pr_verifications, pr.url) %>
                <div class={"px-3 py-3 rounded border transition-all " <>
                  if(pr_work_info,
                    do: "bg-success/10 border-success/30",
                    else: "border-base-300 hover:bg-base-300/50 dark:hover:bg-white/5 hover:border-accent/30 #{status_border}")}>
                  <!-- PR Title and Number -->
                  <div class="flex items-start justify-between mb-2">
                    <div class="flex-1 min-w-0">
                      <a href={pr.url} target="_blank" class="text-ui-body hover:text-accent flex items-center space-x-1">
                        <%= if pr_work_info do %>
                          <span class="status-activity-ring text-success flex-shrink-0" title={"Agent working: #{pr_work_info[:label] || pr_work_info[:slug]}"} aria-label={"Agent working on this PR: " <> (pr_work_info[:label] || pr_work_info[:slug] || "in progress")} role="status"></span>
                        <% end %>
                        <span class="text-ui-value text-accent font-bold">#<%= pr.number %></span>
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
                      class="btn-interactive-sm ml-2 bg-purple-500/20 text-purple-600 dark:text-purple-400 hover:bg-purple-500/40 whitespace-nowrap"
                      title="Request Super Review"
                      aria-label={"Request super review for PR #" <> to_string(pr.number)}
                    >
                      🔍 Review
                    </button>
                  </div>

                  <!-- Author and Branch -->
                  <div class="flex items-center space-x-2 text-ui-caption text-base-content/60 mb-2">
                    <span>by <span class="text-base-content/80"><%= pr.author %></span></span>
                    <span>•</span>
                    <span class="truncate text-blue-600 dark:text-blue-400" title={pr.branch}><%= pr.branch %></span>
                    <span>•</span>
                    <span><%= format_pr_time(pr.created_at) %></span>
                  </div>

                  <!-- Status Row: CI, Review, and Tickets -->
                  <div class="flex items-center space-x-2 flex-wrap gap-2">
                    <!-- CI Status -->
                    <span class={pr_ci_badge(pr.ci_status)} title={"CI Status: " <> pr_ci_text(pr.ci_status)} aria-label={"CI Status: " <> pr_ci_text(pr.ci_status)}>
                      <%= pr_ci_icon(pr.ci_status) %> CI
                    </span>

                    <!-- Conflict Badge -->
                    <%= if pr.has_conflicts do %>
                      <span class="px-1.5 py-0.5 bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 text-ui-caption rounded" title="Has merge conflicts">
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
                          "btn-interactive-sm transition-all duration-150",
                          if(is_fix_pending,
                            do: "bg-warning/30 text-warning cursor-wait",
                            else: if(is_work_in_progress,
                              do: "bg-base-content/10 text-base-content/40 cursor-not-allowed",
                              else: "bg-red-500/20 text-red-600 dark:text-red-400 hover:bg-red-500/40 active:scale-95"
                            )
                          ),
                          "phx-click-loading:bg-warning/30 phx-click-loading:text-warning phx-click-loading:animate-pulse"
                        ]}
                        title={if is_work_in_progress, do: "Agent already working on this PR", else: "Send to coding agent to fix issues"}
                        aria-label={"Fix issues for PR #" <> to_string(pr.number)}
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
                        class="px-1.5 py-0.5 bg-green-500/20 text-green-600 dark:text-green-400 text-ui-caption rounded inline-flex items-center gap-1"
                        title={"Verified by #{verification["verified_by"]} at #{verification["verified_at"]}"}
                      >
                        ✓ Verified
                        <button
                          phx-click="clear_pr_verification"
                          phx-target={@myself}
                          phx-value-url={pr.url}
                          class="ml-0.5 text-green-600/60 dark:text-green-400/60 hover:text-red-500"
                          title="Clear verification"
                          aria-label={"Clear verification for PR #" <> to_string(pr.number)}
                        >✗</button>
                      </span>
                    <% else %>
                      <button
                        phx-click="verify_pr"
                        phx-target={@myself}
                        phx-value-url={pr.url}
                        phx-value-number={pr.number}
                        phx-value-repo={pr.repo}
                        class="px-1.5 py-0.5 bg-base-content/10 text-base-content/60 hover:bg-green-500/20 hover:text-green-600 dark:hover:text-green-400 text-ui-caption rounded"
                        title="Mark as verified"
                        aria-label={"Mark PR #" <> to_string(pr.number) <> " as verified"}
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
                        class="px-1.5 py-0.5 bg-orange-500/20 text-orange-600 dark:text-orange-400 hover:bg-orange-500/40 text-ui-caption rounded"
                        title="View in Linear"
                        aria-label={"View ticket " <> ticket_id <> " in Linear (opens in new tab)"}
                      >
                        <%= ticket_id %>
                      </a>
                    <% end %>

                    <!-- Agent Working Indicator -->
                    <%= if pr_work_info do %>
                      <span class="px-1.5 py-0.5 bg-success/20 text-success text-ui-caption rounded"
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
            <div class="text-ui-caption text-base-content/60 mt-2 text-right">
              Updated <%= format_pr_time(@github_prs_last_updated) %>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
