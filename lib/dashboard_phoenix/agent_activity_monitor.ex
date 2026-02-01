defmodule DashboardPhoenix.AgentActivityMonitor do
  @moduledoc """
  Monitors coding agent activity by parsing session transcripts.
  Watches OpenClaw sessions, Claude Code, OpenCode, and Codex.
  
  This module is a thin wrapper around `AgentActivityMonitor.Server` that provides
  backward compatibility with the existing DashboardPhoenix integration.
  
  ## Architecture
  
  The monitor is composed of three modules:
  
  - `AgentActivityMonitor.Config` - Configuration struct with sensible defaults
  - `AgentActivityMonitor.SessionParser` - Stateless JSONL session parsing
  - `AgentActivityMonitor.Server` - The actual GenServer implementation
  
  This separation allows:
  - Testing session parsing in isolation
  - Running the monitor with custom configuration
  - Reusing components in other applications
  
  ## Usage
  
  For typical DashboardPhoenix use, just add to your supervision tree:
  
      children = [
        # ... other children
        DashboardPhoenix.AgentActivityMonitor
      ]
  
  For custom configuration:
  
      config = %AgentActivityMonitor.Config{
        sessions_dir: "/custom/path",
        poll_interval_ms: 10_000
      }
      
      children = [
        {DashboardPhoenix.AgentActivityMonitor, config: config}
      ]
  
  ## PubSub Integration
  
  The monitor broadcasts activity updates to `"agent_activity"` topic:
  
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_activity")
      
      # Receives {:agent_activity, [%{id: _, status: _, ...}, ...]}
  
  Or use the convenience function:
  
      AgentActivityMonitor.subscribe()
  """

  # Re-export types from SessionParser for convenience
  @type agent_type :: :openclaw | :claude_code | :opencode | :codex | :unknown
  @type action :: DashboardPhoenix.AgentActivityMonitor.SessionParser.action()
  @type agent_activity :: DashboardPhoenix.AgentActivityMonitor.SessionParser.agent_activity()

  # Delegate to Server for the GenServer functionality
  defdelegate start_link(opts \\ []), to: DashboardPhoenix.AgentActivityMonitor.Server

  @doc """
  Get current activity for all monitored agents.
  Returns a list of agent activity maps sorted by last_activity (most recent first).
  """
  @spec get_activity() :: list(agent_activity())
  def get_activity do
    DashboardPhoenix.AgentActivityMonitor.Server.get_activity(__MODULE__)
  end

  @doc """
  Subscribe to agent activity updates via PubSub.
  
  When subscribed, you'll receive messages of the form:
  `{:agent_activity, [%{id: _, status: _, ...}, ...]}`
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    DashboardPhoenix.AgentActivityMonitor.Server.subscribe(__MODULE__)
  end

  @doc """
  Returns the current configuration.
  """
  @spec get_config() :: DashboardPhoenix.AgentActivityMonitor.Config.t()
  def get_config do
    DashboardPhoenix.AgentActivityMonitor.Server.get_config(__MODULE__)
  end

  # Child spec for supervision tree - ensures we start with name: __MODULE__
  def child_spec(opts) do
    config = Keyword.get_lazy(opts, :config, fn ->
      DashboardPhoenix.AgentActivityMonitor.Config.dashboard_defaults()
    end)
    
    # Override name to use this module's name for backward compatibility
    config = %{config | name: __MODULE__}
    
    %{
      id: __MODULE__,
      start: {DashboardPhoenix.AgentActivityMonitor.Server, :start_link, [[config: config]]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end
end
