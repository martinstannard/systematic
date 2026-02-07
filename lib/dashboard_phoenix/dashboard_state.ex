defmodule DashboardPhoenix.DashboardState do
  @moduledoc """
  GenServer for persisting critical dashboard UI state.

  Persists the following state that survives restarts:
  - Panel collapse states (which panels are collapsed/expanded)
  - Dismissed sessions (sessions the user has manually dismissed)
  - Model selections (claude_model, opencode_model preferences)

  Uses atomic writes to prevent corruption.

  ## Async Persistence

  Persistence is done asynchronously to avoid blocking the GenServer.
  State changes are debounced (100ms) to coalesce rapid updates into
  a single write. This improves responsiveness for UI operations like
  panel toggling.
  """
  use GenServer
  require Logger

  alias DashboardPhoenix.FileUtils
  alias DashboardPhoenix.Paths
  alias DashboardPhoenix.Models

  @pubsub DashboardPhoenix.PubSub
  @topic "dashboard_state"

  # Debounce interval for persistence (ms)
  @persist_debounce_ms 100

  # Default state
  @default_state %{
    panels: %{
      config: false,
      linear: false,
      chainlink: false,
      prs: false,
      branches: false,
      opencode: false,
      gemini: false,
      coding_agents: false,
      subagents: false,
      dave: false,
      live_progress: false,
      agent_activity: false,
      system_processes: false,
      process_relationships: false,
      chat: true,
      test_runner: false,
      activity: false,
      work_panel: false
    },
    dismissed_sessions: [],
    models: %{
      claude_model: Models.default_claude_model(),
      opencode_model: Models.default_opencode_model()
    },
    updated_at: nil
  }

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc """
  Get all persisted state.
  """
  @spec get_state() :: map()
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Get panel collapse states.
  Returns a map of panel_name => collapsed boolean.
  """
  @spec get_panels() :: map()
  def get_panels do
    state = get_state()
    state.panels
  end

  @doc """
  Get collapsed state for a specific panel.
  """
  @spec get_panel(atom()) :: boolean()
  def get_panel(panel_name) when is_atom(panel_name) do
    panels = get_panels()
    Map.get(panels, panel_name, false)
  end

  @doc """
  Set panel collapsed state.
  """
  @spec set_panel(atom(), boolean()) :: :ok
  def set_panel(panel_name, collapsed) when is_atom(panel_name) and is_boolean(collapsed) do
    GenServer.call(__MODULE__, {:set_panel, panel_name, collapsed})
  end

  @doc """
  Set all panel states at once.
  """
  @spec set_panels(map()) :: :ok
  def set_panels(panels) when is_map(panels) do
    GenServer.call(__MODULE__, {:set_panels, panels})
  end

  @doc """
  Get dismissed session IDs.
  Returns a list of session IDs.
  """
  @spec get_dismissed_sessions() :: [binary()]
  def get_dismissed_sessions do
    state = get_state()
    state.dismissed_sessions
  end

  @doc """
  Add a session to dismissed list.
  """
  def dismiss_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:dismiss_session, session_id})
  end

  @doc """
  Dismiss multiple sessions at once.
  """
  def dismiss_sessions(session_ids) when is_list(session_ids) do
    GenServer.call(__MODULE__, {:dismiss_sessions, session_ids})
  end

  @doc """
  Clear all dismissed sessions.
  """
  def clear_dismissed_sessions do
    GenServer.call(__MODULE__, :clear_dismissed_sessions)
  end

  @doc """
  Check if a session is dismissed.
  """
  @spec session_dismissed?(binary()) :: boolean()
  def session_dismissed?(session_id) when is_binary(session_id) do
    session_id in get_dismissed_sessions()
  end

  @doc """
  Get model selections.
  Returns a map with :claude_model and :opencode_model.
  """
  @spec get_models() :: map()
  def get_models do
    state = get_state()
    state.models
  end

  @doc """
  Set Claude model selection.
  """
  def set_claude_model(model) when is_binary(model) do
    GenServer.call(__MODULE__, {:set_model, :claude_model, model})
  end

  @doc """
  Set OpenCode model selection.
  """
  def set_opencode_model(model) when is_binary(model) do
    GenServer.call(__MODULE__, {:set_model, :opencode_model, model})
  end

  @doc """
  Set all model selections at once.
  """
  def set_models(models) when is_map(models) do
    GenServer.call(__MODULE__, {:set_models, models})
  end

  @doc """
  Subscribe to state changes.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = load_state()
    # Add persist_timer to track debounced save operations
    {:ok, Map.put(state, :persist_timer, nil)}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call({:set_panel, panel_name, collapsed}, _from, state) do
    new_panels = Map.put(state.panels, panel_name, collapsed)
    new_state = %{state | panels: new_panels, updated_at: now()}
    new_state = schedule_persist(new_state)
    broadcast_change(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_panels, panels}, _from, state) do
    # Convert string keys to atoms and merge with existing panels
    normalized_panels = normalize_panel_keys(panels)
    new_panels = Map.merge(state.panels, normalized_panels)
    new_state = %{state | panels: new_panels, updated_at: now()}
    new_state = schedule_persist(new_state)
    broadcast_change(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:dismiss_session, session_id}, _from, state) do
    if session_id in state.dismissed_sessions do
      {:reply, :ok, state}
    else
      new_dismissed = [session_id | state.dismissed_sessions]
      new_state = %{state | dismissed_sessions: new_dismissed, updated_at: now()}
      new_state = schedule_persist(new_state)
      broadcast_change(new_state)
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:dismiss_sessions, session_ids}, _from, state) do
    new_ids = Enum.reject(session_ids, &(&1 in state.dismissed_sessions))

    if new_ids == [] do
      {:reply, :ok, state}
    else
      new_dismissed = new_ids ++ state.dismissed_sessions
      new_state = %{state | dismissed_sessions: new_dismissed, updated_at: now()}
      new_state = schedule_persist(new_state)
      broadcast_change(new_state)
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call(:clear_dismissed_sessions, _from, state) do
    new_state = %{state | dismissed_sessions: [], updated_at: now()}
    new_state = schedule_persist(new_state)
    broadcast_change(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_model, model_key, value}, _from, state) do
    new_models = Map.put(state.models, model_key, value)
    new_state = %{state | models: new_models, updated_at: now()}
    new_state = schedule_persist(new_state)
    broadcast_change(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:set_models, models}, _from, state) do
    # Normalize keys to atoms
    normalized_models =
      for {k, v} <- models, into: %{} do
        key = if is_binary(k), do: String.to_existing_atom(k), else: k
        {key, v}
      end

    new_models = Map.merge(state.models, normalized_models)
    new_state = %{state | models: new_models, updated_at: now()}
    new_state = schedule_persist(new_state)
    broadcast_change(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:persist, state) do
    save_state(state)
    {:noreply, %{state | persist_timer: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Cancel any pending timer and save immediately on shutdown
    if state.persist_timer, do: Process.cancel_timer(state.persist_timer)
    save_state(state)
    :ok
  end

  # Private functions

  defp schedule_persist(state) do
    # Cancel existing timer if any (debounce)
    if state.persist_timer do
      Process.cancel_timer(state.persist_timer)
    end

    # Schedule new persist after debounce interval
    timer = Process.send_after(self(), :persist, @persist_debounce_ms)
    %{state | persist_timer: timer}
  end

  defp state_file, do: Paths.dashboard_state_file()

  defp load_state do
    file = state_file()

    case File.read(file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            merge_with_defaults(data)

          {:error, reason} ->
            Logger.warning("[DashboardState] Failed to parse state file: #{inspect(reason)}")
            @default_state
        end

      {:error, :enoent} ->
        Logger.info("[DashboardState] No state file found, using defaults")
        @default_state

      {:error, reason} ->
        Logger.warning("[DashboardState] Failed to read state file: #{inspect(reason)}")
        @default_state
    end
  end

  defp merge_with_defaults(data) when is_map(data) do
    panels = data["panels"] || %{}
    dismissed = data["dismissed_sessions"] || []
    models = data["models"] || %{}

    %{
      panels: Map.merge(@default_state.panels, normalize_panel_keys(panels)),
      dismissed_sessions: dismissed,
      models: Map.merge(@default_state.models, normalize_model_keys(models)),
      updated_at: data["updated_at"]
    }
  end

  defp normalize_panel_keys(panels) when is_map(panels) do
    for {k, v} <- panels, into: %{} do
      key =
        if is_binary(k) do
          try do
            String.to_existing_atom(k)
          rescue
            _ -> String.to_atom(k)
          end
        else
          k
        end

      {key, v}
    end
  end

  defp normalize_model_keys(models) when is_map(models) do
    for {k, v} <- models, into: %{} do
      key =
        if is_binary(k) do
          try do
            String.to_existing_atom(k)
          rescue
            _ -> String.to_atom(k)
          end
        else
          k
        end

      {key, v}
    end
  end

  defp save_state(state) do
    file = state_file()

    # Convert atoms to strings for JSON serialization
    data = %{
      "panels" => for({k, v} <- state.panels, into: %{}, do: {Atom.to_string(k), v}),
      "dismissed_sessions" => state.dismissed_sessions,
      "models" => for({k, v} <- state.models, into: %{}, do: {Atom.to_string(k), v}),
      "updated_at" => state.updated_at
    }

    case Jason.encode(data, pretty: true) do
      {:ok, json} ->
        # Ensure directory exists
        File.mkdir_p!(Path.dirname(file))

        case FileUtils.atomic_write(file, json) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.error("[DashboardState] Failed to save state: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("[DashboardState] Failed to encode state: #{inspect(reason)}")
    end
  end

  defp broadcast_change(state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:dashboard_state_updated, state})
  end

  defp now do
    DateTime.utc_now() |> DateTime.to_iso8601()
  end
end
