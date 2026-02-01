defmodule DashboardPhoenix.AgentPreferences do
  @moduledoc """
  GenServer for managing coding agent preferences.
  
  Stores user preference for which coding agent to use:
  - :opencode - OpenCode (Gemini-powered) for coding tasks
  - :claude - Claude sub-agents for when Claude is preferred
  - :gemini - Gemini CLI for direct Gemini interaction
  
  Supports agent distribution modes:
  - "single" - Use the selected coding_agent exclusively
  - "round_robin" - Alternate between claude and opencode
  
  Persists preferences to a JSON file for durability across restarts.
  """
  use GenServer
  require Logger

  alias DashboardPhoenix.FileUtils
  alias DashboardPhoenix.Paths

  defp prefs_file, do: Paths.preferences_file()
  @pubsub DashboardPhoenix.PubSub
  @topic "agent_preferences"

  # Valid coding agents
  @valid_agents ["opencode", "claude", "gemini"]
  
  # Valid agent modes
  @valid_modes ["single", "round_robin"]

  # Default preferences
  @default_prefs %{
    coding_agent: "opencode",  # "opencode", "claude", or "gemini"
    agent_mode: "round_robin",       # "single" or "round_robin"
    last_agent: "claude",       # Last agent used in round_robin mode
    updated_at: nil
  }

  # Client API

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc """
  Get current preferences.
  """
  @spec get_preferences() :: map()
  def get_preferences do
    GenServer.call(__MODULE__, :get_preferences)
  end

  @doc """
  Get current coding agent preference.
  Returns :opencode, :claude, or :gemini
  """
  @spec get_coding_agent() :: :opencode | :claude | :gemini
  def get_coding_agent do
    prefs = get_preferences()
    String.to_atom(prefs.coding_agent)
  end

  @doc """
  Set coding agent preference.
  agent should be "opencode", "claude", or "gemini"
  """
  @spec set_coding_agent(binary()) :: :ok
  def set_coding_agent(agent) when agent in @valid_agents do
    GenServer.call(__MODULE__, {:set_coding_agent, agent})
  end

  @doc """
  Cycle through coding agents: opencode -> claude -> gemini -> opencode
  """
  @spec toggle_coding_agent() :: :ok
  def toggle_coding_agent do
    current = get_coding_agent()
    new_agent = case current do
      :opencode -> "claude"
      :claude -> "gemini"
      :gemini -> "opencode"
    end
    set_coding_agent(new_agent)
  end

  @doc """
  Get list of valid coding agents.
  """
  @spec valid_agents() :: [binary()]
  def valid_agents, do: @valid_agents
  
  @doc """
  Get current agent mode.
  Returns "single" or "round_robin"
  """
  @spec get_agent_mode() :: binary()
  def get_agent_mode do
    prefs = get_preferences()
    prefs.agent_mode
  end
  
  @doc """
  Set agent mode.
  mode should be "single" or "round_robin"
  """
  @spec set_agent_mode(binary()) :: :ok
  def set_agent_mode(mode) when mode in @valid_modes do
    GenServer.call(__MODULE__, {:set_agent_mode, mode})
  end
  
  @doc """
  Get the last agent used in round-robin mode.
  Returns "claude" or "opencode"
  """
  @spec get_last_agent() :: binary()
  def get_last_agent do
    prefs = get_preferences()
    prefs.last_agent
  end
  
  @doc """
  Get the next agent for work dispatch.
  
  In single mode: returns the selected coding_agent
  In round_robin mode: alternates between claude and opencode, updating last_agent
  
  Returns {:ok, agent_atom} where agent_atom is :claude or :opencode (or :gemini in single mode)
  """
  @spec next_agent() :: {:ok, :claude | :opencode | :gemini}
  def next_agent do
    GenServer.call(__MODULE__, :next_agent)
  end
  
  @doc """
  Get list of valid agent modes.
  """
  @spec valid_modes() :: [binary()]
  def valid_modes, do: @valid_modes

  @doc """
  Subscribe to preference changes.
  """
  @spec subscribe() :: :ok
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # Server callbacks

  @impl true
  @spec init(keyword()) :: {:ok, map()}
  def init(_opts) do
    prefs = load_preferences()
    {:ok, prefs}
  end

  @impl true
  @spec handle_call(:get_preferences, GenServer.from(), map()) :: {:reply, map(), map()}
  def handle_call(:get_preferences, _from, prefs) do
    {:reply, prefs, prefs}
  end

  @impl true
  @spec handle_call({:set_coding_agent, binary()}, GenServer.from(), map()) :: {:reply, :ok, map()}
  def handle_call({:set_coding_agent, agent}, _from, prefs) do
    new_prefs = %{prefs | coding_agent: agent, updated_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    save_preferences(new_prefs)
    broadcast_change(new_prefs)
    Logger.info("[AgentPreferences] Coding agent set to: #{agent}")
    {:reply, :ok, new_prefs}
  end
  
  @impl true
  @spec handle_call({:set_agent_mode, binary()}, GenServer.from(), map()) :: {:reply, :ok, map()}
  def handle_call({:set_agent_mode, mode}, _from, prefs) do
    new_prefs = %{prefs | agent_mode: mode, updated_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    save_preferences(new_prefs)
    broadcast_change(new_prefs)
    Logger.info("[AgentPreferences] Agent mode set to: #{mode}")
    {:reply, :ok, new_prefs}
  end
  
  @impl true
  @spec handle_call(:next_agent, GenServer.from(), map()) :: {:reply, {:ok, atom()}, map()}
  def handle_call(:next_agent, _from, prefs) do
    case prefs.agent_mode do
      "round_robin" ->
        # Cycle through all three agents
        next = case prefs.last_agent do
          "claude" -> "opencode"
          "opencode" -> "gemini"
          "gemini" -> "claude"
          _ -> "claude"  # fallback
        end
        new_prefs = %{prefs | last_agent: next, updated_at: DateTime.utc_now() |> DateTime.to_iso8601()}
        save_preferences(new_prefs)
        broadcast_change(new_prefs)
        Logger.info("[AgentPreferences] Round-robin: next agent is #{next}")
        {:reply, {:ok, String.to_atom(next)}, new_prefs}
      
      "single" ->
        # Use the selected coding agent
        {:reply, {:ok, String.to_atom(prefs.coding_agent)}, prefs}
    end
  end

  # Private functions

  defp load_preferences do
    case File.read(prefs_file()) do
      {:ok, content} ->
        case Jason.decode(content, keys: :atoms) do
          {:ok, prefs} ->
            Map.merge(@default_prefs, prefs)
          {:error, _} ->
            Logger.warning("[AgentPreferences] Failed to parse prefs file, using defaults")
            @default_prefs
        end
      {:error, :enoent} ->
        Logger.info("[AgentPreferences] No prefs file found, using defaults")
        @default_prefs
      {:error, reason} ->
        Logger.warning("[AgentPreferences] Failed to read prefs file: #{inspect(reason)}")
        @default_prefs
    end
  end

  defp save_preferences(prefs) do
    case Jason.encode(prefs, pretty: true) do
      {:ok, json} ->
        case FileUtils.atomic_write(prefs_file(), json) do
          :ok -> :ok
          {:error, reason} ->
            Logger.error("[AgentPreferences] Failed to save prefs: #{inspect(reason)}")
        end
      {:error, reason} ->
        Logger.error("[AgentPreferences] Failed to encode prefs: #{inspect(reason)}")
    end
  end

  defp broadcast_change(prefs) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:preferences_updated, prefs})
  end
end
