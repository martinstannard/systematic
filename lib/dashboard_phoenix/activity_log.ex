defmodule DashboardPhoenix.ActivityLog do
  @moduledoc """
  GenServer for tracking high-level workflow events.

  Stores the last 50 events and broadcasts new events via PubSub
  for real-time LiveView updates.

  ## Event Types
  - `:code_complete` - coding task finished
  - `:merge_started` - merge operation initiated
  - `:merge_complete` - merge operation finished
  - `:restart_triggered` - restart was triggered
  - `:restart_complete` - restart finished
  - `:test_passed` - tests passed
  - `:test_failed` - tests failed
  - `:task_started` - new task started

  ## Usage

      # Log an event
      ActivityLog.log_event(:code_complete, "Feature implemented", %{branch: "feature-x"})

      # Get recent events
      events = ActivityLog.get_events(10)

      # Subscribe to new events in LiveView
      ActivityLog.subscribe()
  """

  use GenServer

  @max_events 50
  @pubsub_topic "activity_log:events"
  @valid_event_types ~w(code_complete merge_started merge_complete restart_triggered restart_complete test_passed test_failed task_started)a

  # Client API

  @doc "Start the ActivityLog GenServer"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Log a new event.

  ## Parameters
  - `type` - Event type atom (see module docs)
  - `message` - Human-readable message
  - `details` - Optional map of additional details

  ## Returns
  - `{:ok, event}` - The created event
  - `{:error, :invalid_type}` - If the event type is not valid
  """
  def log_event(type, message, details \\ %{}) when is_atom(type) and is_binary(message) do
    GenServer.call(__MODULE__, {:log_event, type, message, details})
  end

  @doc """
  Get recent events.

  ## Parameters
  - `limit` - Maximum number of events to return (default: 20)

  ## Returns
  List of event maps, most recent first.
  """
  def get_events(limit \\ 20) when is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:get_events, limit})
  end

  @doc """
  Subscribe to new events via PubSub.

  Subscribers receive messages in the format:
  `{:activity_log_event, event}` where event is a map.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @pubsub_topic)
  end

  @doc "Unsubscribe from events"
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(DashboardPhoenix.PubSub, @pubsub_topic)
  end

  @doc "Clear all events (useful for testing)"
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc "Get the list of valid event types"
  def valid_event_types, do: @valid_event_types

  @doc "Get the PubSub topic for activity log events"
  def pubsub_topic, do: @pubsub_topic

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{events: []}}
  end

  @impl true
  def handle_call({:log_event, type, message, details}, _from, state) do
    if type in @valid_event_types do
      event = %{
        id: generate_id(),
        type: type,
        message: message,
        details: details,
        timestamp: DateTime.utc_now()
      }

      # Add to front, trim to max
      new_events = [event | state.events] |> Enum.take(@max_events)

      # Broadcast to subscribers
      Phoenix.PubSub.broadcast(
        DashboardPhoenix.PubSub,
        @pubsub_topic,
        {:activity_log_event, event}
      )

      {:reply, {:ok, event}, %{state | events: new_events}}
    else
      {:reply, {:error, :invalid_type}, state}
    end
  end

  def handle_call({:get_events, limit}, _from, state) do
    events = Enum.take(state.events, limit)
    {:reply, events, state}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | events: []}}
  end

  # Private helpers

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
