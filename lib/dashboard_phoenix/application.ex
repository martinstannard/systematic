defmodule DashboardPhoenix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  @spec start(Application.start_type(), term()) :: {:ok, pid()} | {:error, {:already_started, pid()}} | {:error, term()}
  def start(_type, _args) do
    # Initialize CLI tools cache
    DashboardPhoenix.CLITools.ensure_cache_table()
    
    # Conditional services based on environment
    session_bridge_child = if Application.get_env(:dashboard_phoenix, :disable_session_bridge, false) do
      []
    else
      [DashboardPhoenix.SessionBridge]
    end

    children = [
      DashboardPhoenixWeb.Telemetry,
      DashboardPhoenix.Repo,
      # Rate limiter for external API calls
      DashboardPhoenix.RateLimiter,
      # CLI cache for reducing external command overhead (Ticket #73)
      DashboardPhoenix.CLICache,
      # Task supervisor for async loading (prevents silent failures)
      {Task.Supervisor, name: DashboardPhoenix.TaskSupervisor},
      {DNSCluster, query: Application.get_env(:dashboard_phoenix, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DashboardPhoenix.PubSub},
      # Agent preferences for coding agent toggle
      DashboardPhoenix.AgentPreferences,
      # Dashboard UI state persistence (panels, dismissed sessions, models)
      DashboardPhoenix.DashboardState,
      # Activity log for workflow event tracking
      DashboardPhoenix.ActivityLog,
      # Deploy manager for post-merge deployment pipeline
      DashboardPhoenix.DeployManager,
      # HomeLive memoization cache
      DashboardPhoenixWeb.HomeLiveCache,
    ] ++ session_bridge_child ++ [
      # Session bridge for live agent updates (tails progress files) - conditional
      # OpenCode activity monitor for Live Feed (polls configurable OpenCode storage directory)
      DashboardPhoenix.OpenCodeActivityMonitor,
      # Stats monitor for OpenCode/Claude usage
      DashboardPhoenix.StatsMonitor,
      # Resource tracker for CPU/memory graphs
      DashboardPhoenix.ResourceTracker,
      # Agent activity monitor for "what's it doing" feature
      DashboardPhoenix.AgentActivityMonitor,
      # Linear ticket monitor for COR team
      DashboardPhoenix.LinearMonitor,
      # Chainlink issue monitor for local issues
      DashboardPhoenix.ChainlinkMonitor,
      # Chainlink work-in-progress persistence
      DashboardPhoenix.ChainlinkWorkTracker,
      # GitHub PR monitor
      DashboardPhoenix.PRMonitor,
      # Unmerged branches monitor
      DashboardPhoenix.BranchMonitor,
      # Git commit/merge event monitor
      DashboardPhoenix.GitMonitor,
      # OpenCode ACP server manager
      DashboardPhoenix.OpenCodeServer,
      # Gemini CLI server manager
      DashboardPhoenix.GeminiServer,
      # Health check for dashboard self-monitoring
      DashboardPhoenix.HealthCheck,
      # Start to serve requests, typically the last entry
      DashboardPhoenixWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DashboardPhoenix.Supervisor]
    result = Supervisor.start_link(children, opts)
    
    # Log startup event after supervision tree is up
    case result do
      {:ok, _pid} ->
        # Small delay to ensure ActivityLog GenServer is ready
        spawn(fn ->
          Process.sleep(1000)
          DashboardPhoenix.ActivityLog.log_event(:restart_complete, "Dashboard started", %{version: "1.0"})
        end)
      _ ->
        :ok
    end
    
    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  @spec config_change(keyword(), keyword(), [atom()]) :: :ok
  def config_change(changed, _new, removed) do
    DashboardPhoenixWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
