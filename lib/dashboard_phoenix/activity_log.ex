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
  - `:subagent_started` - sub-agent spawned
  - `:subagent_completed` - sub-agent finished successfully
  - `:subagent_failed` - sub-agent finished with failure
  - `:git_commit` - new commit detected on monitored branch
  - `:git_merge` - merge commit detected on monitored branch

  ## Usage

      # Log an event
      ActivityLog.log_event(:code_complete, "Feature implemented", %{branch: "feature-x"})

      # Get recent events
      events = ActivityLog.get_events(10)

      # Subscribe to new events in LiveView
      ActivityLog.subscribe()
  """

  use GenServer
  require Logger

  alias DashboardPhoenix.FileUtils

  @max_events 50
  @pubsub_topic "activity_log:events"
  @events_file "priv/activity_events.json"
  @valid_event_types ~w(code_complete merge_started merge_complete restart_triggered restart_complete deploy_complete restart_failed test_passed test_failed task_started code_merged session_cleanup subagent_started subagent_completed subagent_failed git_commit git_merge)a

  # Client API

  @doc "Start the ActivityLog GenServer"
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
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
  @spec log_event(atom(), binary(), map()) :: {:ok, map()} | {:error, :invalid_type}
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
  @spec get_events(pos_integer()) :: [map()]
  def get_events(limit \\ 20) when is_integer(limit) and limit > 0 do
    GenServer.call(__MODULE__, {:get_events, limit})
  end

  @doc """
  Subscribe to new events via PubSub.

  Subscribers receive messages in the format:
  `{:activity_log_event, event}` where event is a map.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @pubsub_topic)
  end

  @doc "Unsubscribe from events"
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(DashboardPhoenix.PubSub, @pubsub_topic)
  end

  @doc "Clear all events (useful for testing)"
  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc "Get the list of valid event types"
  @spec valid_event_types() :: [atom()]
  def valid_event_types, do: @valid_event_types

  @doc "Get the PubSub topic for activity log events"
  @spec pubsub_topic() :: binary()
  def pubsub_topic, do: @pubsub_topic

  # Server Callbacks

  @impl true
  @spec init(term()) :: {:ok, map()}
  def init(_opts) do
    events = load_events_from_file()
    {:ok, %{events: events}}
  end

  @impl true
  @spec handle_call({:log_event, atom(), binary(), map()}, GenServer.from(), map()) :: 
          {:reply, {:ok, map()} | {:error, :invalid_type}, map()}
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

      # Persist to file
      save_events_to_file(new_events)

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

  @spec handle_call({:get_events, pos_integer()}, GenServer.from(), map()) :: {:reply, [map()], map()}
  def handle_call({:get_events, limit}, _from, state) do
    events = Enum.take(state.events, limit)
    {:reply, events, state}
  end

  @spec handle_call(:clear, GenServer.from(), map()) :: {:reply, :ok, map()}
  def handle_call(:clear, _from, state) do
    # Also clear the persisted file
    File.rm(@events_file)
    {:reply, :ok, %{state | events: []}}
  end

  # Private helpers

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp load_events_from_file do
    case File.read(@events_file) do
      {:ok, content} ->
        try do
          content
          |> Jason.decode!()
          |> Enum.map(&decode_event/1)
          |> Enum.take(@max_events)
        rescue
          e in Jason.DecodeError ->
            Logger.warning("ActivityLog: Failed to decode events JSON: #{Exception.message(e)}")
            []
          e ->
            Logger.warning("ActivityLog: Exception decoding events: #{inspect(e)}")
            []
        end

      {:error, :enoent} ->
        Logger.debug("ActivityLog: Events file #{@events_file} does not exist, starting with empty log")
        []
      {:error, :eacces} ->
        Logger.warning("ActivityLog: Permission denied reading events file #{@events_file}")
        []
      {:error, reason} ->
        Logger.warning("ActivityLog: Failed to read events file #{@events_file}: #{inspect(reason)}")
        []
    end
  rescue
    e ->
      Logger.error("ActivityLog: Exception loading events from file: #{inspect(e)}")
      []
  end

  defp save_events_to_file(events) do
    try do
      case events
           |> Enum.map(&encode_event/1)
           |> Jason.encode(pretty: true) do
        {:ok, content} ->
          # Use atomic write to prevent file corruption on crash or concurrent access
          case FileUtils.atomic_write(@events_file, content) do
            :ok ->
              Logger.debug("ActivityLog: Successfully saved #{length(events)} events")
              :ok
            {:error, reason} ->
              Logger.error("ActivityLog: Failed to save events file: #{inspect(reason)}")
              {:error, reason}
          end
        {:error, %Jason.EncodeError{} = e} ->
          Logger.error("ActivityLog: Failed to encode events as JSON: #{Exception.message(e)}")
          {:error, {:json_encode, e}}
        {:error, reason} ->
          Logger.error("ActivityLog: JSON encode error for events: #{inspect(reason)}")
          {:error, {:json_encode, reason}}
      end
    rescue
      e ->
        Logger.error("ActivityLog: Exception saving events to file: #{inspect(e)}")
        {:error, {:exception, e}}
    end
  end

  defp encode_event(event) do
    %{
      "id" => event.id,
      "type" => Atom.to_string(event.type),
      "message" => event.message,
      "details" => encode_details(event.details),
      "timestamp" => DateTime.to_iso8601(event.timestamp)
    }
  end

  defp decode_event(data) do
    %{
      id: data["id"],
      type: String.to_existing_atom(data["type"]),
      message: data["message"],
      details: decode_details(data["details"]),
      timestamp: parse_timestamp(data["timestamp"])
    }
  end

  defp encode_details(details) when is_map(details) do
    Map.new(details, fn {k, v} -> {to_string(k), v} end)
  end

  defp decode_details(details) when is_map(details) do
    Map.new(details, fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp decode_details(_), do: %{}

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(_), do: DateTime.utc_now()
end
