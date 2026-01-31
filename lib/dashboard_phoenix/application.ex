defmodule DashboardPhoenix.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      DashboardPhoenixWeb.Telemetry,
      DashboardPhoenix.Repo,
      {DNSCluster, query: Application.get_env(:dashboard_phoenix, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: DashboardPhoenix.PubSub},
      # Agent preferences for coding agent toggle
      DashboardPhoenix.AgentPreferences,
      # Session bridge for live agent updates (tails progress files)
      DashboardPhoenix.SessionBridge,
      # Stats monitor for OpenCode/Claude usage
      DashboardPhoenix.StatsMonitor,
      # Resource tracker for CPU/memory graphs
      DashboardPhoenix.ResourceTracker,
      # Agent activity monitor for "what's it doing" feature
      DashboardPhoenix.AgentActivityMonitor,
      # Linear ticket monitor for COR team
      DashboardPhoenix.LinearMonitor,
      # GitHub PR monitor
      DashboardPhoenix.PRMonitor,
      # OpenCode ACP server manager
      DashboardPhoenix.OpenCodeServer,
      # Start to serve requests, typically the last entry
      DashboardPhoenixWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DashboardPhoenix.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DashboardPhoenixWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
