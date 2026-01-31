defmodule DashboardPhoenix.OpenClawClient do
  @moduledoc """
  Client for sending messages to OpenClaw agent sessions.
  
  Uses the `openclaw agent` CLI command to inject messages into the main session.
  When the agent receives a "Work on ticket X" message, it will spawn a coding
  sub-agent to handle the task.
  
  Also supports spawning isolated sub-agents directly via the cron system for
  tasks like PR fixes and reviews that shouldn't clutter the main session.
  """
  require Logger

  @behaviour DashboardPhoenix.Behaviours.OpenClawClientBehaviour

  @default_timeout 30_000

  @doc """
  Send a work request to OpenClaw to spawn a coding agent for a ticket.
  
  Options:
  - :ticket_id - Linear ticket ID (e.g., "COR-123")
  - :details - Ticket description/details
  - :model - Model to use for the sub-agent (e.g., "anthropic/claude-opus-4-5")
  - :timeout - Command timeout in ms (default: 30s)
  """
  def work_on_ticket(ticket_id, details, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    model = Keyword.get(opts, :model, nil)
    
    # Build the message for the agent
    message = build_work_message(ticket_id, details, model)
    
    # Run openclaw agent command
    args = [
      "agent",
      "--message", message,
      "--deliver",
      "--channel", "webchat"
    ]
    
    Logger.info("[OpenClawClient] Sending work request for #{ticket_id} with model: #{model || "default"}")
    
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
    channel = Keyword.get(opts, :channel, "webchat")
    
    args = [
      "agent",
      "--agent", "main",
      "--message", message,
      "--deliver",
      "--channel", channel
    ]
    
    Logger.info("[OpenClawClient] Sending message (async): #{String.slice(message, 0, 100)}...")
    
    # Fire and forget - don't block waiting for agent response
    Task.start(fn ->
      case System.cmd("openclaw", args, stderr_to_stdout: true) do
        {_output, 0} ->
          Logger.info("[OpenClawClient] Message delivered successfully")
        {output, code} ->
          Logger.error("[OpenClawClient] Command failed (#{code}): #{output}")
      end
    end)
    
    {:ok, :sent}
  end

  @doc """
  Spawn an isolated sub-agent to handle a task without cluttering the main session.
  
  Uses the OpenClaw cron system to create a one-shot job that runs in an isolated
  session. The job auto-deletes after completion and posts a summary back to main.
  
  Options:
  - :name - Job name (will be prefixed with "dashboard-")
  - :model - Model to use (e.g., "anthropic/claude-sonnet-4-20250514")
  - :thinking - Thinking level (off|minimal|low|medium|high)
  - :post_mode - What to post back to main ("summary"|"full")
  - :timeout - Command timeout in ms (default: 30s)
  """
  def spawn_subagent(task_message, opts \\ []) do
    name = Keyword.get(opts, :name, "task-#{:rand.uniform(999_999)}")
    model = Keyword.get(opts, :model)
    thinking = Keyword.get(opts, :thinking, "low")
    post_mode = Keyword.get(opts, :post_mode, "summary")
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    
    # Build the cron add command
    args = [
      "cron", "add",
      "--name", "dashboard-#{name}",
      "--session", "isolated",
      "--at", "1m",  # Schedule for 1 minute (minimum supported)
      "--delete-after-run",  # Auto-cleanup after completion
      "--wake", "now",  # Run immediately, don't wait for heartbeat
      "--message", task_message,
      "--thinking", thinking,
      "--post-mode", post_mode,
      "--json"
    ]
    
    # Add model if specified
    args = if model, do: args ++ ["--model", model], else: args
    
    Logger.info("[OpenClawClient] Spawning isolated sub-agent: dashboard-#{name}")
    
    case System.cmd("openclaw", args, stderr_to_stdout: true, timeout: timeout) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, %{"id" => job_id}} ->
            Logger.info("[OpenClawClient] Sub-agent spawned successfully: #{job_id}")
            {:ok, %{job_id: job_id, name: "dashboard-#{name}"}}
          
          {:ok, response} ->
            Logger.info("[OpenClawClient] Sub-agent spawned: #{inspect(response)}")
            {:ok, %{name: "dashboard-#{name}", response: response}}
          
          {:error, _} ->
            Logger.warning("[OpenClawClient] Sub-agent spawned but couldn't parse response: #{output}")
            {:ok, %{name: "dashboard-#{name}", output: output}}
        end
      
      {output, code} ->
        Logger.error("[OpenClawClient] Spawn failed (#{code}): #{output}")
        {:error, "openclaw cron add failed: #{output}"}
    end
  rescue
    e ->
      Logger.error("[OpenClawClient] Exception spawning sub-agent: #{inspect(e)}")
      {:error, "Exception: #{inspect(e)}"}
  end

  # Build the work message that tells the agent to spawn a coding sub-agent
  defp build_work_message(ticket_id, details, model) do
    model_instruction = if model do
      "\n**Model:** Use #{model} for the sub-agent when spawning.\n"
    else
      ""
    end

    """
    🎫 **Work Request from Systematic Dashboard**
    
    Please spawn a coding sub-agent to work on this ticket:#{model_instruction}
    **Ticket:** #{ticket_id}
    
    **Details:**
    #{details || "No details provided - look up the ticket using linear-cli."}
    
    Use a git worktree for isolation. When done, commit with a detailed message.
    """
  end
end
