defmodule DashboardPhoenix.AgentPreferences do
  @moduledoc """
  GenServer for managing coding agent preferences.
  
  Stores user preference for which coding agent to use:
  - :opencode - OpenCode (Gemini-powered) for coding tasks
  - :claude - Claude sub-agents for when Claude is preferred
  - :gemini - Gemini CLI for direct Gemini interaction
  
  Persists preferences to a JSON file for durability across restarts.
  """
  use GenServer
  require Logger

  alias DashboardPhoenix.FileUtils

  @prefs_file "/tmp/dashboard-prefs.json"
  @pubsub DashboardPhoenix.PubSub
  @topic "agent_preferences"

  # Valid coding agents
  @valid_agents ["opencode", "claude", "gemini"]

  # Default preferences
  @default_prefs %{
    coding_agent: "opencode",  # "opencode", "claude", or "gemini"
    updated_at: nil
  }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current preferences.
  """
  def get_preferences do
    GenServer.call(__MODULE__, :get_preferences)
  end

  @doc """
  Get current coding agent preference.
  Returns :opencode, :claude, or :gemini
  """
  def get_coding_agent do
    prefs = get_preferences()
    String.to_atom(prefs.coding_agent)
  end

  @doc """
  Set coding agent preference.
  agent should be "opencode", "claude", or "gemini"
  """
  def set_coding_agent(agent) when agent in @valid_agents do
    GenServer.call(__MODULE__, {:set_coding_agent, agent})
  end

  @doc """
  Cycle through coding agents: opencode -> claude -> gemini -> opencode
  """
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
  def valid_agents, do: @valid_agents

  @doc """
  Subscribe to preference changes.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    prefs = load_preferences()
    {:ok, prefs}
  end

  @impl true
  def handle_call(:get_preferences, _from, prefs) do
    {:reply, prefs, prefs}
  end

  @impl true
  def handle_call({:set_coding_agent, agent}, _from, prefs) do
    new_prefs = %{prefs | coding_agent: agent, updated_at: DateTime.utc_now() |> DateTime.to_iso8601()}
    save_preferences(new_prefs)
    broadcast_change(new_prefs)
    Logger.info("[AgentPreferences] Coding agent set to: #{agent}")
    {:reply, :ok, new_prefs}
  end

  # Private functions

  defp load_preferences do
    case File.read(@prefs_file) do
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
        case FileUtils.atomic_write(@prefs_file, json) do
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
