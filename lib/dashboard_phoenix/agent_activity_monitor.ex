defmodule DashboardPhoenix.AgentActivityMonitor do
  @moduledoc """
  Dashboard-specific wrapper for AgentActivityMonitor.

  This module provides backward compatibility with the existing DashboardPhoenix
  integration by wrapping the portable `AgentActivityMonitor` core with
  dashboard-specific defaults.

  ## Usage

  For typical DashboardPhoenix use, just add to your supervision tree:

      children = [
        # ... other children
        DashboardPhoenix.AgentActivityMonitor
      ]

  For custom configuration, use the portable core directly:

      config = AgentActivityMonitor.Config.new(sessions_dir,
        pubsub: {DashboardPhoenix.PubSub, "agent_activity"},
        name: MyApp.CustomMonitor
      )
      
      children = [
        {AgentActivityMonitor, config: config}
      ]

  ## PubSub Integration

  The monitor broadcasts activity updates to the "agent_activity" topic:

      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_activity")
      
      # Receives {:agent_activity, [%{id: _, status: _, ...}, ...]}

  Or use the convenience function:

      DashboardPhoenix.AgentActivityMonitor.subscribe()
  """

  # Re-export types from the portable module
  @type agent_type :: AgentActivityMonitor.agent_type()
  @type action :: AgentActivityMonitor.action()
  @type agent_activity :: AgentActivityMonitor.agent_activity()

  @doc """
  Get current activity for all monitored agents.
  Returns a list of agent activity maps sorted by last_activity (most recent first).
  """
  @spec get_activity() :: list(agent_activity())
  def get_activity do
    AgentActivityMonitor.Server.get_activity(__MODULE__)
  end

  @doc """
  Subscribe to agent activity updates via PubSub.

  When subscribed, you'll receive messages of the form:
  `{:agent_activity, [%{id: _, status: _, ...}, ...]}`
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    AgentActivityMonitor.Server.subscribe(__MODULE__)
  end

  @doc """
  Returns the current configuration.
  """
  @spec get_config() :: AgentActivityMonitor.Config.t()
  def get_config do
    AgentActivityMonitor.Server.get_config(__MODULE__)
  end

  @doc """
  Creates the dashboard-specific configuration.

  This configuration includes:
  - Sessions directory from DashboardPhoenix.Paths
  - PubSub broadcasting to agent_activity topic
  - TaskSupervisor for async operations
  - State persistence via DashboardPhoenix.StatePersistence
  - Memory/GC utilities from DashboardPhoenix.MemoryUtils
  - Process monitoring via DashboardPhoenix.ProcessParser
  """
  @spec dashboard_config() :: AgentActivityMonitor.Config.t()
  def dashboard_config do
    alias DashboardPhoenix.PubSub.Topics

    %AgentActivityMonitor.Config{
      sessions_dir: DashboardPhoenix.Paths.openclaw_sessions_dir(),
      pubsub: {DashboardPhoenix.PubSub, Topics.agent_activity()},
      task_supervisor: DashboardPhoenix.TaskSupervisor,
      save_state: &DashboardPhoenix.StatePersistence.save/2,
      load_state: &DashboardPhoenix.StatePersistence.load/2,
      gc_trigger: &DashboardPhoenix.MemoryUtils.trigger_gc/1,
      find_processes: &find_coding_agent_processes/1,
      monitor_processes?: true,
      name: __MODULE__
    }
  end

  # Child spec for supervision tree - uses dashboard defaults
  def child_spec(opts) do
    config = Keyword.get_lazy(opts, :config, &dashboard_config/0)

    # Ensure name is set for backward compatibility
    config = %{config | name: __MODULE__}

    %{
      id: __MODULE__,
      start: {AgentActivityMonitor.Server, :start_link, [[config: config]]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # Dashboard-specific process finder that uses DashboardPhoenix.ProcessParser
  defp find_coding_agent_processes(timeout_ms) do
    if Code.ensure_loaded?(DashboardPhoenix.ProcessParser) do
      DashboardPhoenix.ProcessParser.list_processes(
        sort: "-start_time",
        filter: &coding_agent_process?/1,
        timeout: timeout_ms
      )
      |> Enum.map(&transform_process_to_agent/1)
      |> Map.new(fn a -> {a.id, a} end)
    else
      %{}
    end
  end

  defp coding_agent_process?(line) do
    patterns = ~w(claude opencode codex)
    line_lower = String.downcase(line)

    Enum.any?(patterns, &String.contains?(line_lower, &1)) and
      not String.contains?(line_lower, "grep") and
      not String.contains?(line_lower, "ps aux")
  end

  defp transform_process_to_agent(%{pid: pid, cpu: cpu, mem: mem, start: start, command: command}) do
    type = detect_agent_type(command)
    cwd = get_process_cwd(pid)

    %{
      id: "process-#{pid}",
      session_id: pid,
      type: type,
      model: detect_model_from_command(command),
      cwd: cwd,
      status: if(cpu > 5.0, do: "busy", else: "idle"),
      last_action: nil,
      recent_actions: [],
      files_worked: [],
      last_activity: DateTime.utc_now(),
      cpu: "#{cpu}%",
      memory: "#{mem}%",
      start_time: start,
      tool_call_count: 0
    }
  end

  defp detect_agent_type(command) do
    cmd_lower = String.downcase(command)

    cond do
      String.contains?(cmd_lower, "claude") -> :claude_code
      String.contains?(cmd_lower, "opencode") -> :opencode
      String.contains?(cmd_lower, "codex") -> :codex
      String.contains?(cmd_lower, "gemini") -> :gemini
      true -> :unknown
    end
  end

  defp detect_model_from_command(command) do
    cond do
      String.contains?(command, "opus") -> "claude-opus"
      String.contains?(command, "sonnet") -> "claude-sonnet"
      String.contains?(command, "gemini") -> "gemini"
      true -> "unknown"
    end
  end

  defp get_process_cwd(pid) do
    DashboardPhoenix.ProcessCwd.get!(pid)
  end
end
