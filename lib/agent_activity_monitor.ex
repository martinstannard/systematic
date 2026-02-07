defmodule AgentActivityMonitor do
  @moduledoc """
  Portable agent activity monitor for coding agents.

  Monitors OpenClaw, Claude Code, OpenCode, and Codex sessions by parsing
  their session transcripts. Designed to be easily embedded in any Elixir
  application.

  ## Architecture

  The monitor is composed of three modules:

  - `AgentActivityMonitor.Config` - Configuration struct with sensible defaults
  - `AgentActivityMonitor.SessionParser` - Stateless JSONL session parsing
  - `AgentActivityMonitor.Server` - The GenServer implementation

  ## Quick Start

  ### Standalone Usage

      # Start the monitor
      config = AgentActivityMonitor.Config.minimal("/path/to/sessions")
      {:ok, pid} = AgentActivityMonitor.start_link(config: config)
      
      # Get activity
      activities = AgentActivityMonitor.Server.get_activity(pid)

  ### With Phoenix/LiveView

      # In your application.ex
      config = AgentActivityMonitor.Config.new(sessions_dir,
        pubsub: {MyApp.PubSub, "agent_activity"},
        task_supervisor: MyApp.TaskSupervisor,
        name: MyApp.AgentMonitor
      )
      
      children = [
        # ...
        {AgentActivityMonitor, config: config}
      ]
      
      # In your LiveView
      def mount(_params, _session, socket) do
        if connected?(socket) do
          AgentActivityMonitor.Server.subscribe(MyApp.AgentMonitor)
        end
        activities = AgentActivityMonitor.Server.get_activity(MyApp.AgentMonitor)
        {:ok, assign(socket, activities: activities)}
      end
      
      def handle_info({:agent_activity, activities}, socket) do
        {:noreply, assign(socket, activities: activities)}
      end

  ### Parsing Files Directly

  For batch processing or testing, use SessionParser directly:

      {:ok, activity} = AgentActivityMonitor.SessionParser.parse_file(path)
      
      # Or parse content
      activity = AgentActivityMonitor.SessionParser.parse_content(content, filename)
  """

  @type agent_type :: :openclaw | :claude_code | :opencode | :codex | :unknown
  @type action :: AgentActivityMonitor.SessionParser.action()
  @type agent_activity :: AgentActivityMonitor.SessionParser.agent_activity()

  @doc """
  Starts the AgentActivityMonitor server.

  ## Options
  - `:config` - A `AgentActivityMonitor.Config` struct (required)
  - `:name` - GenServer name (overrides config.name)

  ## Example

      config = AgentActivityMonitor.Config.minimal("/tmp/sessions")
      {:ok, pid} = AgentActivityMonitor.start_link(config: config)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  defdelegate start_link(opts), to: AgentActivityMonitor.Server

  @doc """
  Creates a minimal config for the given sessions directory.

  Convenience function that wraps `AgentActivityMonitor.Config.minimal/1`.
  """
  @spec minimal_config(String.t()) :: AgentActivityMonitor.Config.t()
  defdelegate minimal_config(sessions_dir), to: AgentActivityMonitor.Config, as: :minimal

  @doc """
  Creates a config with custom options.

  Convenience function that wraps `AgentActivityMonitor.Config.new/2`.
  """
  @spec new_config(String.t(), keyword()) :: AgentActivityMonitor.Config.t()
  defdelegate new_config(sessions_dir, opts \\ []), to: AgentActivityMonitor.Config, as: :new

  # Provide child_spec for supervision tree
  def child_spec(opts) do
    config = Keyword.fetch!(opts, :config)

    %{
      id: config.name || __MODULE__,
      start: {AgentActivityMonitor.Server, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end
end
