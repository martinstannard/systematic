defmodule DashboardPhoenixWeb.Live.Components.LinearComponent do
  @moduledoc """
  Smart LiveComponent for displaying and interacting with Linear tickets.

  ## Smart Component Pattern

  This component is "smart" - it manages its own state internally rather than
  relying on parent assigns for everything. The parent only needs to:

  1. Call `LinearComponent.subscribe()` in its mount
  2. Forward PubSub messages using `LinearComponent.handle_pubsub/2`
  3. Pass minimal required assigns (collapsed state, tickets_in_progress)

  The component handles:
  - Loading state
  - Filtering
  - Status counts
  - All UI events (except work_on_ticket which needs cross-component coordination)
  """
  use DashboardPhoenixWeb, :live_component

  alias DashboardPhoenix.InputValidator
  alias DashboardPhoenix.Status
  alias DashboardPhoenix.LinearMonitor

  # ============================================================================
  # Public API for Parent Integration
  # ============================================================================

  @doc """
  Subscribe to Linear ticket updates. Call this in the parent's mount/3.
  """
  def subscribe do
    LinearMonitor.subscribe()
  end

  @doc """
  Handle a PubSub message. Call this from the parent's handle_info/2.
  Returns :ok if handled, :skip if not a Linear message.

  ## Example

      def handle_info(msg, socket) do
        case LinearComponent.handle_pubsub(msg, socket) do
          :ok -> {:noreply, socket}
          :skip -> # handle other messages
        end
      end
  """
  def handle_pubsub({:linear_update, data}, socket) do
    send_update(socket.assigns.live_action || __MODULE__, __MODULE__,
      id: :linear,
      linear_data: data
    )

    :ok
  end

  def handle_pubsub(_msg, _socket), do: :skip

  @doc """
  Trigger a refresh of Linear tickets. Can be called from anywhere.
  """
  def refresh do
    LinearMonitor.refresh()
  end

  # ============================================================================
  # LiveComponent Callbacks
  # ============================================================================

  @impl true
  def mount(socket) do
    # Initialize component state
    {:ok,
     assign(socket,
       tickets: [],
       filtered_tickets: [],
       tickets_count: 0,
       counts: %{},
       last_updated: nil,
       error: nil,
       loading: true,
       status_filter: Status.in_review()
     )}
  end

  @impl true
  def update(assigns, socket) do
    # First, always apply parent assigns (collapsed, tickets_in_progress, id)
    socket =
      socket
      |> assign(:collapsed, Map.get(assigns, :collapsed, socket.assigns[:collapsed] || false))
      |> assign(
        :tickets_in_progress,
        Map.get(assigns, :tickets_in_progress, socket.assigns[:tickets_in_progress] || %{})
      )
      |> assign(:id, assigns.id)

    # Then handle linear_data if present (PubSub update)
    socket =
      case Map.get(assigns, :linear_data) do
        %{tickets: tickets} = data ->
          counts = Enum.frequencies_by(tickets, & &1.status)
          filtered_tickets = filter_tickets(tickets, socket.assigns.status_filter)

          assign(socket,
            tickets: tickets,
            filtered_tickets: filtered_tickets,
            tickets_count: length(tickets),
            counts: counts,
            last_updated: data.last_updated,
            error: data[:error],
            loading: false
          )

        nil ->
          # No linear_data - check if we need initial data fetch
          if socket.assigns.loading and socket.assigns.tickets == [] do
            case LinearMonitor.get_tickets() do
              %{tickets: tickets} = data ->
                counts = Enum.frequencies_by(tickets, & &1.status)
                filtered_tickets = filter_tickets(tickets, socket.assigns.status_filter)

                assign(socket,
                  tickets: tickets,
                  filtered_tickets: filtered_tickets,
                  tickets_count: length(tickets),
                  counts: counts,
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
  def handle_event("set_linear_filter", %{"status" => status}, socket) do
    case InputValidator.validate_filter_string(status) do
      {:ok, validated_status} ->
        filtered_tickets = filter_tickets(socket.assigns.tickets, validated_status)

        {:noreply,
         assign(socket,
           status_filter: validated_status,
           filtered_tickets: filtered_tickets
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Invalid status filter: #{reason}")}
    end
  end

  @impl true
  def handle_event("toggle_panel", _, socket) do
    # Notify parent to update collapsed state (persisted in DashboardState)
    send(self(), {:linear_component, :toggle_panel})
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh_linear", _, socket) do
    LinearMonitor.refresh()
    {:noreply, assign(socket, loading: true)}
  end

  @impl true
  def handle_event("work_on_ticket", %{"id" => ticket_id}, socket) do
    # Work on ticket needs cross-component coordination (opens modal, etc.)
    # So we still forward this to parent
    case InputValidator.validate_linear_ticket_id(ticket_id) do
      {:ok, validated_ticket_id} ->
        send(self(), {:linear_component, :work_on_ticket, validated_ticket_id})
        {:noreply, socket}

      {:error, _reason} ->
        case InputValidator.validate_general_id(ticket_id) do
          {:ok, validated_ticket_id} ->
            send(self(), {:linear_component, :work_on_ticket, validated_ticket_id})
            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Invalid ticket ID: #{reason}")}
        end
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp filter_tickets(tickets, status) do
    tickets
    |> Enum.filter(&(&1.status == status))
    |> Enum.take(10)
  end

  defp linear_filter_button_active(status) do
    cond do
      status == Status.triage() ->
        "bg-red-500/20 text-red-600 dark:text-red-400 border border-red-500/30"

      status == Status.backlog() ->
        "bg-blue-500/20 text-blue-600 dark:text-blue-400 border border-blue-500/30"

      status == Status.todo() ->
        "bg-yellow-500/20 text-yellow-600 dark:text-yellow-400 border border-yellow-500/30"

      status == Status.in_review() ->
        "bg-purple-500/20 text-purple-600 dark:text-purple-400 border border-purple-500/30"

      true ->
        "bg-accent/20 text-accent border border-accent/30"
    end
  end

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
        aria-controls="linear-panel-content"
        aria-label="Toggle Linear tickets panel"
        onkeydown="if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.click(); }"
      >
        <div class="flex items-center space-x-2">
          <span class={"panel-chevron " <> if(@collapsed, do: "collapsed", else: "")}>▼</span>
          <span class="panel-icon">🎫</span>
          <span class="text-panel-label text-accent">Linear</span>
          <%= if @loading do %>
            <span class="status-activity-ring text-accent" aria-hidden="true"></span>
            <span class="sr-only">Loading tickets</span>
          <% else %>
            <span class="text-ui-caption text-tabular text-base-content/60">{@tickets_count}</span>
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

      <div
        id="linear-panel-content"
        class={"transition-all duration-300 ease-in-out overflow-hidden " <> if(@collapsed, do: "max-h-0", else: "max-h-[400px]")}
      >
        <div class="px-5 pb-5 pt-2">
          <!-- Status Filter -->
          <div class="flex items-center flex-wrap gap-2 mb-4">
            <%= for status <- Status.linear_states() do %>
              <% count = Map.get(@counts, status, 0) %>
              <button
                phx-click="set_linear_filter"
                phx-value-status={status}
                phx-target={@myself}
                class={"px-2.5 py-2 sm:py-1 text-ui-caption transition-all rounded min-h-[44px] sm:min-h-0 " <>
                  if(@status_filter == status,
                    do: linear_filter_button_active(status),
                    else: "bg-base-content/10 text-base-content/60 hover:bg-base-content/20 border border-transparent"
                  )}
                role="button"
                aria-pressed={if(@status_filter == status, do: "true", else: "false")}
                aria-label={"Filter tickets by #{status} status, #{count} tickets"}
              >
                {status} ({count})
              </button>
            <% end %>
          </div>
          
    <!-- Ticket List -->
          <div
            class="space-y-3 max-h-[300px] overflow-y-auto"
            role="region"
            aria-live="polite"
            aria-label="Linear ticket list"
          >
            <%= if @loading do %>
              <div class="flex items-center justify-center py-4 space-x-2">
                <span class="throbber-small"></span>
                <span class="text-ui-caption text-base-content/60">Loading tickets...</span>
              </div>
            <% else %>
              <%= if @error do %>
                <div class="text-ui-caption text-error py-2 px-2">{@error}</div>
              <% end %>
              <%= if @filtered_tickets == [] and is_nil(@error) do %>
                <div class="text-ui-caption text-base-content/60 py-4 text-center">
                  No tickets found
                </div>
              <% end %>
              <%= for ticket <- @filtered_tickets do %>
                <% work_info = Map.get(@tickets_in_progress, ticket.id) %>
                <div class={"flex flex-col sm:flex-row sm:items-center gap-2 sm:space-x-3 px-3 py-3 sm:py-2 rounded border transition-all " <> if(work_info, do: "bg-success/10 border-success/30", else: "border-base-300 hover:bg-base-300/50 dark:hover:bg-white/5 hover:border-accent/30")}>
                  <div class="flex items-center gap-2 w-full sm:w-auto">
                    <%= if work_info do %>
                      <span class="status-activity-ring text-success flex-shrink-0" aria-hidden="true">
                      </span>
                      <span class="sr-only">Work in progress</span>
                    <% else %>
                      <button
                        phx-click="work_on_ticket"
                        phx-value-id={ticket.id}
                        phx-target={@myself}
                        class="btn-interactive-sm min-w-[44px] min-h-[44px] sm:min-w-0 sm:min-h-0 bg-accent/20 text-accent hover:bg-accent/40 hover:scale-105 active:scale-95 flex-shrink-0"
                        aria-label={"Start work on ticket " <> ticket.id}
                        title={"Start work on ticket " <> ticket.id}
                      >
                        <span aria-hidden="true">▶</span>
                      </button>
                    <% end %>
                    <a
                      href={ticket.url}
                      target="_blank"
                      class="text-ui-value text-accent hover:underline flex-shrink-0"
                    >
                      {ticket.id}
                    </a>
                  </div>
                  <span class="text-ui-body truncate w-full sm:flex-1" title={ticket.title}>
                    {ticket.title}
                  </span>
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
