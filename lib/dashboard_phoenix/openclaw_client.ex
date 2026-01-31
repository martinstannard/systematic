defmodule DashboardPhoenix.OpenClawClient do
  @moduledoc """
  Client for sending messages to OpenClaw agent sessions.
  
  Uses the `openclaw agent` CLI command to inject messages into the main session.
  When the agent receives a "Work on ticket X" message, it will spawn a coding
  sub-agent to handle the task.
  """
  require Logger

  @default_timeout 30_000

  @doc """
  Send a work request to OpenClaw to spawn a coding agent for a ticket.
  
  Options:
  - :ticket_id - Linear ticket ID (e.g., "COR-123")
  - :details - Ticket description/details
  - :timeout - Command timeout in ms (default: 30s)
  """
  def work_on_ticket(ticket_id, details, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    
    # Build the message for the agent
    message = build_work_message(ticket_id, details)
    
    # Run openclaw agent command
    args = [
      "agent",
      "--message", message,
      "--deliver",
      "--channel", "webchat"
    ]
    
    Logger.info("[OpenClawClient] Sending work request for #{ticket_id}")
    
    case System.cmd("openclaw", args, stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        Logger.info("[OpenClawClient] Success: #{String.slice(output, 0, 200)}")
        {:ok, %{ticket_id: ticket_id, output: output}}
      
      {output, code} ->
        Logger.error("[OpenClawClient] Command failed (#{code}): #{output}")
        {:error, "openclaw agent failed: #{output}"}
    end
  rescue
    e ->
      Logger.error("[OpenClawClient] Exception: #{inspect(e)}")
      {:error, "Exception: #{inspect(e)}"}
  end

  @doc """
  Send a raw message to the OpenClaw main session.
  """
  def send_message(message, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    channel = Keyword.get(opts, :channel, "webchat")
    
    args = [
      "agent",
      "--message", message,
      "--deliver",
      "--channel", channel
    ]
    
    Logger.info("[OpenClawClient] Sending message: #{String.slice(message, 0, 100)}...")
    
    case System.cmd("openclaw", args, stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        {:ok, output}
      
      {output, code} ->
        Logger.error("[OpenClawClient] Command failed (#{code}): #{output}")
        {:error, "openclaw agent failed: #{output}"}
    end
  rescue
    e ->
      Logger.error("[OpenClawClient] Exception: #{inspect(e)}")
      {:error, "Exception: #{inspect(e)}"}
  end

  # Build the work message that tells the agent to spawn a coding sub-agent
  defp build_work_message(ticket_id, details) do
    """
    🎫 **Work Request from Systematic Dashboard**
    
    Please spawn a coding sub-agent to work on this ticket:
    
    **Ticket:** #{ticket_id}
    
    **Details:**
    #{details || "No details provided - look up the ticket using linear-cli."}
    
    Use a git worktree for isolation. When done, commit with a detailed message.
    """
  end
end
