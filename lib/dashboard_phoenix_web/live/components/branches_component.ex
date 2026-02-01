defmodule DashboardPhoenixWeb.Live.Components.BranchesComponent do
  @moduledoc """
  LiveComponent for displaying and interacting with unmerged Git branches.

  Extracted from HomeLive to improve code organization and maintainability.
  Shows branches with worktree status, commit info, and merge/delete actions.
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:unmerged_branches_count, fn ->
        length(Map.get(assigns, :unmerged_branches, []))
      end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    send(self(), {:branches_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_branches", _, socket) do
    send(self(), {:branches_component, :refresh})
    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_merge_branch", %{"name" => branch_name}, socket) do
    case InputValidator.validate_branch_name(branch_name) do
      {:ok, validated_branch_name} ->
        send(self(), {:branches_component, :confirm_merge, validated_branch_name})
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid branch name: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_merge_branch", _, socket) do
    send(self(), {:branches_component, :cancel_merge})
    {:noreply, socket}
  end

  @impl true
  def handle_event("execute_merge_branch", %{"name" => branch_name}, socket) do
    case InputValidator.validate_branch_name(branch_name) do
      {:ok, validated_branch_name} ->
        send(self(), {:branches_component, :execute_merge, validated_branch_name})
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid branch name: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_delete_branch", %{"name" => branch_name}, socket) do
    case InputValidator.validate_branch_name(branch_name) do
      {:ok, validated_branch_name} ->
        send(self(), {:branches_component, :confirm_delete, validated_branch_name})
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid branch name: #{reason}")
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel_delete_branch", _, socket) do
    send(self(), {:branches_component, :cancel_delete})
    {:noreply, socket}
  end

  @impl true
  def handle_event("execute_delete_branch", %{"name" => branch_name}, socket) do
    case InputValidator.validate_branch_name(branch_name) do
      {:ok, validated_branch_name} ->
        send(self(), {:branches_component, :execute_delete, validated_branch_name})
        {:noreply, socket}

      {:error, reason} ->
        socket = put_flash(socket, :error, "Invalid branch name: #{reason}")
        {:noreply, socket}
    end
  end

  # Helper functions

  # Format branch time for display
  defp format_branch_time(nil), do: ""

  defp format_branch_time(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  defp format_branch_time(_), do: ""

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
        aria-expanded={if(@branches_collapsed, do: "false", else: "true")}
        aria-controls="branches-panel-content"
        aria-label="Toggle Unmerged Branches panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@branches_collapsed, do: "collapsed", else: "")}>
            ▼
          </span>
          <span class="panel-icon">🌿</span>
          <span class="text-panel-label text-accent">Unmerged Branches</span>
          <%= if @branches_loading do %>
            <span class="status-activity-ring text-accent" aria-hidden="true"></span>
            <span class="sr-only">Loading branches</span>
          <% else %>
            <span class="text-ui-caption text-tabular text-base-content/60">
              {@unmerged_branches_count}
            </span>
          <% end %>
        </div>
        <button
          phx-click="refresh_branches"
          phx-target={@myself}
          class="btn-interactive-icon text-base-content/60 hover:text-accent hover:bg-accent/10 !min-h-[32px] !min-w-[32px] !p-1"
          onclick="event.stopPropagation()"
          aria-label="Refresh branches"
          title="Refresh branches"
        >
          <span class="text-sm" aria-hidden="true">↻</span>
        </button>
      </div>

      <div
        id="branches-panel-content"
        class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@branches_collapsed, do: "max-h-0", else: "max-h-[400px]")}
      >
        <div class="px-5 pb-5 pt-2">
          <!-- Branch List -->
          <div
            class="space-y-3 max-h-[350px] overflow-y-auto"
            role="region"
            aria-live="polite"
            aria-label="Unmerged branches list"
          >
            <%= if @branches_loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-ui-caption text-base-content/60">Loading branches...</span>
              </div>
            <% else %>
              <%= if @branches_error do %>
                <div class="text-ui-caption text-error py-2 px-2">{@branches_error}</div>
              <% end %>
              <%= if @unmerged_branches == [] do %>
                <div class="text-ui-caption text-base-content/60 py-4 text-center">
                  No unmerged branches
                </div>
              <% end %>
              <%= for branch <- @unmerged_branches do %>
                <div class="px-3 py-3 rounded border border-base-300 hover:bg-base-300/50 dark:hover:bg-white/5 hover:border-accent/30 transition-all">
                  <!-- Branch Name and Actions -->
                  <div class="flex items-start justify-between mb-1">
                    <div class="flex items-center space-x-2 min-w-0">
                      <%= if branch.has_worktree do %>
                        <span
                          class="text-green-600 dark:text-green-400"
                          title={"Worktree: #{branch.worktree_path}"}
                        >
                          🌲
                        </span>
                      <% else %>
                        <span class="text-base-content/40">🔀</span>
                      <% end %>
                      <span class="text-ui-body truncate" title={branch.name}>{branch.name}</span>
                      <span class="px-1.5 py-0.5 bg-blue-500/20 text-blue-600 dark:text-blue-400 text-ui-caption rounded">
                        +{branch.commits_ahead}
                      </span>
                    </div>
                    
    <!-- Action Buttons -->
                    <div class="flex items-center space-x-1 ml-2">
                      <%= if @branch_merge_pending == branch.name do %>
                        <!-- Merge Confirmation -->
                        <span class="text-ui-caption text-warning mr-1">Merge?</span>
                        <button
                          phx-click="execute_merge_branch"
                          phx-target={@myself}
                          phx-value-name={branch.name}
                          class="btn-interactive-sm bg-green-500/20 text-green-600 dark:text-green-400 hover:bg-green-500/40"
                          aria-label={"Confirm merge of branch " <> branch.name}
                        >
                          ✓
                        </button>
                        <button
                          phx-click="cancel_merge_branch"
                          phx-target={@myself}
                          class="btn-interactive-sm bg-base-content/10 text-base-content/60 hover:bg-base-content/20"
                          aria-label="Cancel merge"
                        >
                          ✗
                        </button>
                      <% else %>
                        <%= if @branch_delete_pending == branch.name do %>
                          <!-- Delete Confirmation -->
                          <span class="text-ui-caption text-error mr-1">Delete?</span>
                          <button
                            phx-click="execute_delete_branch"
                            phx-target={@myself}
                            phx-value-name={branch.name}
                            class="btn-interactive-sm bg-red-500/20 text-red-600 dark:text-red-400 hover:bg-red-500/40"
                            aria-label={"Confirm delete of branch " <> branch.name}
                          >
                            ✓
                          </button>
                          <button
                            phx-click="cancel_delete_branch"
                            phx-target={@myself}
                            class="btn-interactive-sm bg-base-content/10 text-base-content/60 hover:bg-base-content/20"
                            aria-label="Cancel delete"
                          >
                            ✗
                          </button>
                        <% else %>
                          <!-- Normal Buttons -->
                          <button
                            phx-click="confirm_merge_branch"
                            phx-target={@myself}
                            phx-value-name={branch.name}
                            class="btn-interactive-sm bg-green-500/20 text-green-600 dark:text-green-400 hover:bg-green-500/40"
                            title="Merge to main"
                            aria-label={"Merge branch " <> branch.name <> " to main"}
                          >
                            ⤵ Merge
                          </button>
                          <button
                            phx-click="confirm_delete_branch"
                            phx-target={@myself}
                            phx-value-name={branch.name}
                            class="btn-interactive-sm bg-red-500/20 text-red-600 dark:text-red-400 hover:bg-red-500/40"
                            title="Delete branch"
                            aria-label={"Delete branch " <> branch.name}
                          >
                            <span aria-hidden="true">🗑</span>
                            <span class="sr-only">Delete</span>
                          </button>
                        <% end %>
                      <% end %>
                    </div>
                  </div>
                  
    <!-- Last Commit Info -->
                  <div class="flex items-center space-x-2 text-ui-caption text-base-content/60">
                    <%= if branch.last_commit_message do %>
                      <span class="truncate flex-1" title={branch.last_commit_message}>
                        {branch.last_commit_message}
                      </span>
                      <span>•</span>
                    <% end %>
                    <%= if branch.last_commit_author do %>
                      <span class="text-base-content/60">{branch.last_commit_author}</span>
                      <span>•</span>
                    <% end %>
                    <%= if branch.last_commit_date do %>
                      <span>{format_branch_time(branch.last_commit_date)}</span>
                    <% end %>
                  </div>
                  
    <!-- Worktree Path if applicable -->
                  <%= if branch.has_worktree do %>
                    <div
                      class="text-ui-caption text-green-600/70 dark:text-green-400/60 mt-1 truncate"
                      title={branch.worktree_path}
                    >
                      📁 {branch.worktree_path}
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
          
    <!-- Last Updated -->
          <%= if @branches_last_updated do %>
            <div class="text-ui-caption text-base-content/60 mt-2 text-right">
              Updated {format_branch_time(@branches_last_updated)}
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
