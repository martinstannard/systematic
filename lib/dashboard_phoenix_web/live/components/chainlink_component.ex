defmodule DashboardPhoenixWeb.Live.Components.ChainlinkComponent do
  @moduledoc """
  Smart LiveComponent for displaying and interacting with Chainlink issues.

  ## Smart Component Pattern

  This component is "smart" - it manages its own state internally rather than
  relying on parent assigns for everything. The parent only needs to:

  1. Call `ChainlinkComponent.subscribe()` in its mount
  2. Forward PubSub messages using `ChainlinkComponent.handle_pubsub/2`
  3. Pass minimal required assigns (collapsed state, work_in_progress)

  The component handles:
  - Loading state
  - Issue list management
  - Error handling
  - All UI events (except work_on_issue which needs cross-component coordination)
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator
  alias DashboardPhoenix.ChainlinkMonitor

  # ============================================================================
  # Public API for Parent Integration
  # ============================================================================

  @doc """
  Subscribe to Chainlink issue updates. Call this in the parent's mount/3.
  """
  def subscribe do
    ChainlinkMonitor.subscribe()
  end

  @doc """
  Handle a PubSub message. Call this from the parent's handle_info/2.
  Returns :ok if handled, :skip if not a Chainlink message.

  ## Example

      def handle_info(msg, socket) do
        case ChainlinkComponent.handle_pubsub(msg, socket) do
          :ok -> {:noreply, socket}
          :skip -> # handle other messages
        end
      end
  """
  def handle_pubsub({:chainlink_update, data}, _socket) do
    send_update(__MODULE__,
      id: "chainlink-issues",
      chainlink_data: data
    )

    :ok
  end

  def handle_pubsub(_msg, _socket), do: :skip

  @doc """
  Trigger a refresh of Chainlink issues. Can be called from anywhere.
  """
  def refresh do
    ChainlinkMonitor.refresh()
  end

  @doc """
  Get current issues from the monitor (for initial load).
  """
  def get_issues do
    ChainlinkMonitor.get_issues()
  end

  # ============================================================================
  # LiveComponent Callbacks
  # ============================================================================

  @impl true
  def mount(socket) do
    # Initialize component state
    {:ok,
     assign(socket,
       issues: [],
       issues_count: 0,
       last_updated: nil,
       error: nil,
       loading: true,
       confirm_issue: nil,
       # Form state for creating new issues
       show_create_form: false,
       form_submitting: false,
       form_errors: %{}
     )}
  end

  @impl true
  def update(assigns, socket) do
    # First, always apply parent assigns (collapsed, work_in_progress, id)
    socket =
      socket
      |> assign(:collapsed, Map.get(assigns, :collapsed, socket.assigns[:collapsed] || false))
      |> assign(
        :work_in_progress,
        Map.get(assigns, :work_in_progress, socket.assigns[:work_in_progress] || %{})
      )
      |> assign(:id, assigns.id)

    # Handle creation complete notification
    socket =
      case Map.get(assigns, :creation_complete) do
        %{success: success} ->
          socket = assign(socket, form_submitting: false)
          if success do
            assign(socket, show_create_form: false, form_errors: %{})
          else
            socket
          end
        nil ->
          socket
      end

    # Then handle chainlink_data if present (PubSub update)
    socket =
      case Map.get(assigns, :chainlink_data) do
        %{issues: issues} = data ->
          assign(socket,
            issues: issues,
            issues_count: length(issues),
            last_updated: data.last_updated,
            error: data[:error],
            loading: false
          )

        nil ->
          # No chainlink_data - check if we need initial data fetch
          if socket.assigns.loading and socket.assigns.issues == [] do
            case ChainlinkMonitor.get_issues() do
              %{issues: issues} = data ->
                assign(socket,
                  issues: issues,
                  issues_count: length(issues),
                  last_updated: data.last_updated,
                  error: data[:error],
                  loading: false
                )

              _ ->
                socket
            end
          else
            socket
          end
      end

    {:ok, socket}
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("toggle_panel", _, socket) do
    # Notify parent to update collapsed state (persisted in DashboardState)
    send(self(), {:chainlink_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_chainlink", _, socket) do
    ChainlinkMonitor.refresh()
    {:noreply, assign(socket, loading: true)}
  end

  @impl true
  def handle_event("show_work_confirm", %{"id" => issue_id}, socket) do
    case InputValidator.validate_chainlink_issue_id(issue_id) do
      {:ok, validated_issue_id} ->
        # Find the issue to show in the modal
        issue = Enum.find(socket.assigns.issues, &(&1.id == validated_issue_id))
        {:noreply, assign(socket, confirm_issue: issue)}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("confirm_work", _, socket) do
    if socket.assigns.confirm_issue do
      issue_id = socket.assigns.confirm_issue.id
      # Work on issue needs cross-component coordination (spawns agents, etc.)
      # So we still forward this to parent
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

  @impl true
  def handle_event("reset_form", _, socket) do
    {:noreply, assign(socket, show_create_form: false, form_errors: %{}, form_submitting: false)}
  end

  @impl true
  def handle_event("toggle_create_form", _, socket) do
    new_show_state = !socket.assigns.show_create_form
    socket = assign(socket, 
      show_create_form: new_show_state,
      form_errors: %{}  # Clear any existing errors when toggling
    )
    {:noreply, socket}
  end

  @impl true
  def handle_event("create_chainlink_issue", params, socket) do
    # Extract form data with defaults
    title = String.trim(params["title"] || "")
    description = String.trim(params["description"] || "")
    priority = params["priority"] || "low"

    # Validate form data
    errors = validate_form_data(title, description, priority)

    if map_size(errors) == 0 do
      # Set submitting state
      socket = assign(socket, form_submitting: true, form_errors: %{})
      
      # Send form data to parent to handle CLI execution
      send(self(), {:chainlink_component, :create_issue, %{
        title: title,
        description: description, 
        priority: priority
      }})
      
      {:noreply, socket}
    else
      {:noreply, assign(socket, form_errors: errors)}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Form validation for creating new issues
  defp validate_form_data(title, description, priority) do
    errors = %{}
    
    # Validate title
    errors = 
      cond do
        String.length(title) == 0 ->
          Map.put(errors, :title, "Title is required")
        String.length(title) < 5 ->
          Map.put(errors, :title, "Title should be at least 5 characters")
        String.length(title) > 200 ->
          Map.put(errors, :title, "Title must be 200 characters or less")
        String.match?(title, ~r/^\s*$/) ->
          Map.put(errors, :title, "Title cannot be only whitespace")
        true ->
          errors
      end
    
    # Validate description
    errors = 
      cond do
        String.length(description) > 1000 ->
          Map.put(errors, :description, "Description must be 1000 characters or less")
        description != "" and String.length(description) < 10 ->
          Map.put(errors, :description, "If provided, description should be at least 10 characters")
        true ->
          errors
      end
    
    # Validate priority
    errors = 
      if priority not in ["low", "medium", "high"] do
        Map.put(errors, :priority, "Priority must be low, medium, or high")
      else
        errors
      end
    
    errors
  end

  defp priority_badge(:high),
    do: "px-1.5 py-0.5 bg-red-500/20 text-red-400 dark:text-red-400 text-ui-caption rounded"

  defp priority_badge(:medium),
    do:
      "px-1.5 py-0.5 bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 text-ui-caption rounded"

  defp priority_badge(:low),
    do: "px-1.5 py-0.5 bg-blue-500/20 text-blue-600 dark:text-blue-400 text-ui-caption rounded"

  defp priority_badge(_),
    do: "px-1.5 py-0.5 bg-base-content/10 text-base-content/60 text-ui-caption rounded"

  defp priority_text(:high), do: "HIGH"
  defp priority_text(:medium), do: "MED"
  defp priority_text(:low), do: "LOW"
  defp priority_text(_), do: "UNKNOWN"

  defp priority_symbol(:high), do: "▲"
  defp priority_symbol(:medium), do: "◆"
  defp priority_symbol(:low), do: "▼"
  defp priority_symbol(_), do: "◌"

  defp priority_row_class(priority) do
    case priority do
      :high -> "border-l-2 border-l-red-500/50"
      :medium -> "border-l-2 border-l-yellow-500/50"
      :low -> "border-l-2 border-l-blue-500/50"
      _ -> ""
    end
  end

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

  # Format agent label for display - extracts meaningful name from label
  defp format_agent_label(nil), do: "Working"

  defp format_agent_label(label) when is_binary(label) do
    case Regex.run(~r/ticket-\d+-(.+)$/, label) do
      [_, suffix] ->
        suffix
        |> String.replace("-", " ")
        |> String.split()
        |> Enum.take(3)
        |> Enum.join(" ")

      _ ->
        label
    end
  end

  defp format_agent_label(_), do: "Working"

  # ============================================================================
  # Render
  # ============================================================================

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
        aria-expanded={if(@collapsed, do: "false", else: "true")}
        aria-controls="chainlink-panel-content"
        aria-label="Toggle Chainlink issues panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">🔗</span>
          <span class="text-panel-label text-accent">Chainlink</span>
          <%= if @loading do %>
            <span class="status-activity-ring text-accent" aria-hidden="true"></span>
            <span class="sr-only">Loading issues</span>
          <% else %>
            <span class="text-ui-caption text-tabular text-base-content/60">{@issues_count}</span>
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

      <div
        id="chainlink-panel-content"
        class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@collapsed, do: "max-h-0", else: "max-h-[400px]")}
      >
        <div class="px-5 pb-5 pt-2">
          <!-- Legend: Priority & Status - hidden on mobile for space -->
          <div class="hidden sm:flex items-center justify-between mb-4 text-ui-caption text-base-content/60">
            <div class="flex items-center space-x-3">
              <span class="flex items-center gap-1 text-red-600 dark:text-red-400">
                {priority_symbol(:high)} HIGH
              </span>
              <span class="flex items-center gap-1 text-yellow-600 dark:text-yellow-400">
                {priority_symbol(:medium)} MED
              </span>
              <span class="flex items-center gap-1 text-blue-600 dark:text-blue-400">
                {priority_symbol(:low)} LOW
              </span>
            </div>
            <div class="flex items-center space-x-3 border-l border-base-300 pl-3">
              <span class="flex items-center gap-1">
                <span class="text-base-content/60">○</span> Open
              </span>
              <span class="flex items-center gap-1"><span class="text-success">●</span> Closed</span>
            </div>
          </div>
          
          <!-- Create New Issue Section -->
          <div class="mb-4">
            <button
              phx-click="toggle_create_form"
              phx-target={@myself}
              class="btn-interactive-primary bg-gradient-to-r from-accent to-accent/80 text-white hover:from-accent/90 hover:to-accent/70 transition-all duration-200 w-full py-3 font-semibold shadow-lg hover:shadow-xl transform hover:scale-[1.02] active:scale-[0.98]"
              aria-label="Toggle create new issue form"
            >
              <%= if @show_create_form do %>
                <span aria-hidden="true" class="text-lg">▼</span>
                <span>Hide Create Form</span>
              <% else %>
                <span aria-hidden="true" class="text-lg font-bold">+</span>
                <span>Create New Chainlink Issue</span>
              <% end %>
            </button>

            <%= if @show_create_form do %>
              <div class="mt-3 p-5 bg-gradient-to-br from-base-100 to-base-200/50 border border-base-300 rounded-xl shadow-lg">
                <div class="flex items-center gap-2 mb-4">
                  <span class="text-2xl">🔗</span>
                  <h3 class="text-lg font-semibold text-base-content">Create New Chainlink Issue</h3>
                </div>
                
                <form 
                  phx-submit="create_chainlink_issue" 
                  phx-target={@myself} 
                  id="create-issue-form" 
                  class="space-y-4"
                  phx-hook="ChainlinkCreateForm"
                >
                  <!-- Title Field -->
                  <div>
                    <label for="issue-title" class="block text-ui-label text-base-content mb-2 font-medium">
                      Issue Title <span class="text-error font-bold">*</span>
                    </label>
                    <input
                      type="text"
                      id="issue-title"
                      name="title"
                      maxlength="200"
                      required
                      autofocus={@show_create_form and not @form_submitting}
                      class={"input input-bordered w-full text-ui-body focus:ring-2 focus:ring-accent/50 focus:border-accent transition-colors " <> if Map.get(@form_errors, :title), do: "input-error border-error", else: ""}
                      placeholder="Describe what needs to be done..."
                      disabled={@form_submitting}
                    />
                    <%= if error = Map.get(@form_errors, :title) do %>
                      <p class="text-error text-ui-caption mt-1 flex items-center gap-1">
                        <span aria-hidden="true">⚠</span>
                        {error}
                      </p>
                    <% end %>
                  </div>

                  <!-- Description Field -->
                  <div>
                    <label for="issue-description" class="block text-ui-label text-base-content mb-2 font-medium">
                      Description
                      <span class="text-base-content/60 font-normal">(optional)</span>
                    </label>
                    <textarea
                      id="issue-description"
                      name="description"
                      maxlength="1000"
                      rows="3"
                      class={"textarea textarea-bordered w-full text-ui-body resize-none focus:ring-2 focus:ring-accent/50 focus:border-accent transition-colors " <> if Map.get(@form_errors, :description), do: "textarea-error border-error", else: ""}
                      placeholder="Provide additional context, requirements, or notes..."
                      disabled={@form_submitting}
                    ></textarea>
                    <%= if error = Map.get(@form_errors, :description) do %>
                      <p class="text-error text-ui-caption mt-1 flex items-center gap-1">
                        <span aria-hidden="true">⚠</span>
                        {error}
                      </p>
                    <% end %>
                  </div>

                  <!-- Priority Field -->
                  <div>
                    <label for="issue-priority" class="block text-ui-label text-base-content mb-2 font-medium">
                      Priority Level
                    </label>
                    <select
                      id="issue-priority"
                      name="priority"
                      class={"select select-bordered w-full text-ui-body focus:ring-2 focus:ring-accent/50 focus:border-accent transition-colors " <> if Map.get(@form_errors, :priority), do: "select-error border-error", else: ""}
                      disabled={@form_submitting}
                    >
                      <option value="low" selected>🔵 Low - Nice to have improvement</option>
                      <option value="medium">🟡 Medium - Should be addressed soon</option>
                      <option value="high">🔴 High - Needs immediate attention</option>
                    </select>
                    <%= if error = Map.get(@form_errors, :priority) do %>
                      <p class="text-error text-ui-caption mt-1 flex items-center gap-1">
                        <span aria-hidden="true">⚠</span>
                        {error}
                      </p>
                    <% end %>
                  </div>

                  <!-- Submit Button -->
                  <div class="pt-2">
                    <button
                      type="submit"
                      class={"btn w-full py-3 font-semibold text-white transition-all duration-200 shadow-lg hover:shadow-xl transform " <> if @form_submitting, do: "btn-disabled bg-accent/50 cursor-wait", else: "btn-accent bg-gradient-to-r from-accent to-accent/80 hover:from-accent/90 hover:to-accent/70 hover:scale-[1.02] active:scale-[0.98]"}
                      disabled={@form_submitting}
                    >
                      <%= if @form_submitting do %>
                        <span class="loading loading-spinner loading-sm"></span>
                        <span>Creating Issue...</span>
                      <% else %>
                        <span aria-hidden="true" class="text-lg font-bold">✨</span>
                        <span>Create Issue</span>
                      <% end %>
                    </button>
                  </div>
                  
                  <!-- Success/Error Messages -->
                  <%= if @form_submitting do %>
                    <div class="mt-3 p-3 bg-blue-50 border border-blue-200 rounded-lg text-blue-800 text-sm">
                      <div class="flex items-center gap-2">
                        <span class="loading loading-spinner loading-sm text-blue-600"></span>
                        <span>Processing your request...</span>
                      </div>
                    </div>
                  <% end %>
                </form>
              </div>
            <% end %>
          </div>
          
    <!-- Issue List -->
          <div
            class="space-y-3 max-h-[300px] overflow-y-auto"
            role="region"
            aria-live="polite"
            aria-label="Chainlink issue list"
          >
            <%= if @loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-ui-caption text-base-content/60">Loading issues...</span>
              </div>
            <% else %>
              <%= if @error do %>
                <div class="text-ui-caption text-error py-2 px-2">{@error}</div>
              <% end %>
              <%= if @issues == [] and is_nil(@error) do %>
                <div class="text-ui-caption text-base-content/60 py-4 text-center">
                  No open issues
                </div>
              <% end %>
              <%= for issue <- @issues do %>
                <% work_info = Map.get(@work_in_progress, issue.id) %>
                <div class={"flex flex-col sm:flex-row sm:items-center gap-2 sm:space-x-3 px-3 py-3 sm:py-2 rounded border border-base-300 " <> priority_row_class(issue.priority) <> " " <> wip_row_class(work_info)}>
                  <div class="flex items-center gap-2 sm:gap-3">
                    <%= if work_info do %>
                      <!-- Work in progress indicator - replaces Work button -->
                      <div
                        class="flex items-center space-x-1.5 min-w-[70px] max-w-[120px]"
                        role="status"
                        aria-label={"Work in progress by " <> (work_info[:label] || "agent")}
                      >
                        <span
                          class="status-activity-ring text-success flex-shrink-0"
                          aria-hidden="true"
                        >
                        </span>
                        <span
                          class="text-ui-caption text-success font-medium truncate"
                          title={work_info[:label] || "Working"}
                        >
                          {format_agent_label(work_info[:label])}
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
                    <span
                      class={status_icon_class(issue.status)}
                      title={status_text(issue.status)}
                      aria-label={status_text(issue.status)}
                    >
                      {status_icon(issue.status)}
                    </span>
                    <span class="text-ui-value text-accent">#{issue.id}</span>
                    <span
                      class={priority_badge(issue.priority) <> " sm:hidden"}
                      title={"Priority: " <> priority_text(issue.priority)}
                    >
                      {priority_symbol(issue.priority)}
                    </span>
                  </div>
                  <span class="text-ui-body truncate flex-1" title={issue.title}>{issue.title}</span>
                  <span
                    class={"hidden sm:inline " <> priority_badge(issue.priority)}
                    title={"Priority: " <> priority_text(issue.priority)}
                  >
                    {priority_symbol(issue.priority)} {priority_text(issue.priority)}
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
          phx-target={@myself}
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
                <h2
                  id="chainlink-confirm-title"
                  class="text-lg font-bold text-gray-900 dark:text-gray-100"
                >
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
                <span class="text-ui-value text-accent font-bold">#{@confirm_issue.id}</span>
                <span class={priority_badge(@confirm_issue.priority)}>
                  {priority_symbol(@confirm_issue.priority)} {priority_text(@confirm_issue.priority)}
                </span>
              </div>
              <p class="text-ui-body text-gray-800 dark:text-gray-200">{@confirm_issue.title}</p>
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
                <span aria-hidden="true">▶</span> Start Work
              </button>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
