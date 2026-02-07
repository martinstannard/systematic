defmodule DashboardPhoenix.AgentActivityMonitor.Server do
  @moduledoc """
  Deprecated: Use `AgentActivityMonitor.Server` directly.

  This module exists only for backward compatibility. All functionality
  has been moved to the portable `AgentActivityMonitor.Server` module.
  """

  @deprecated "Use AgentActivityMonitor.Server instead"
  defdelegate start_link(opts), to: AgentActivityMonitor.Server

  @deprecated "Use AgentActivityMonitor.Server instead"
  defdelegate get_activity(server), to: AgentActivityMonitor.Server

  @deprecated "Use AgentActivityMonitor.Server instead"
  defdelegate subscribe(server), to: AgentActivityMonitor.Server

  @deprecated "Use AgentActivityMonitor.Server instead"
  defdelegate get_config(server), to: AgentActivityMonitor.Server

  @deprecated "Use AgentActivityMonitor.Server instead"
  defdelegate poll_now(server), to: AgentActivityMonitor.Server
end
