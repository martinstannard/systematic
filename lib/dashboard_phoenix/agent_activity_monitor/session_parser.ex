defmodule DashboardPhoenix.AgentActivityMonitor.SessionParser do
  @moduledoc """
  Deprecated: Use `AgentActivityMonitor.SessionParser` directly.

  This module exists only for backward compatibility. All functionality
  has been moved to the portable `AgentActivityMonitor.SessionParser` module.
  """

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate parse_file(path, opts \\ []), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate parse_content(content, filename, opts \\ []), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate parse_jsonl_line(line), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate extract_agent_activity(events, filename, max_actions \\ 10),
    to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate extract_tool_calls(events, max_actions \\ 10),
    to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate extract_files_from_tool_call(tool_call), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate extract_files_from_command(command), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate determine_status(last_message, tool_calls), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate has_pending_tool_calls?(message), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate format_action(action), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate parse_timestamp(ts), to: AgentActivityMonitor.SessionParser

  @deprecated "Use AgentActivityMonitor.SessionParser instead"
  defdelegate truncate(str, max), to: AgentActivityMonitor.SessionParser
end
