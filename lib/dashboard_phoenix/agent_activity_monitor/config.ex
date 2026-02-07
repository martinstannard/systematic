defmodule DashboardPhoenix.AgentActivityMonitor.Config do
  @moduledoc """
  Deprecated: Use `AgentActivityMonitor.Config` directly.

  This module exists only for backward compatibility. All functionality
  has been moved to the portable `AgentActivityMonitor.Config` module.
  """

  @deprecated "Use AgentActivityMonitor.Config instead"
  defdelegate minimal(sessions_dir), to: AgentActivityMonitor.Config

  @deprecated "Use AgentActivityMonitor.Config instead"
  defdelegate new(sessions_dir, opts \\ []), to: AgentActivityMonitor.Config

  @deprecated "Use AgentActivityMonitor.Config instead"
  defdelegate validate(config), to: AgentActivityMonitor.Config

  @doc """
  Creates a Config with DashboardPhoenix defaults.

  Use `DashboardPhoenix.AgentActivityMonitor.dashboard_config/0` instead.
  """
  @deprecated "Use DashboardPhoenix.AgentActivityMonitor.dashboard_config/0 instead"
  @spec dashboard_defaults() :: AgentActivityMonitor.Config.t()
  def dashboard_defaults do
    DashboardPhoenix.AgentActivityMonitor.dashboard_config()
  end
end
