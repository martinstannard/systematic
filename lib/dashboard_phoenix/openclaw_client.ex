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

  alias DashboardPhoenix.CommandRunner
  @behaviour DashboardPhoenix.Behaviours.OpenClawClientBehaviour

  # Type definitions
  @typedoc "Options for work_on_ticket: :model"
  @type work_opts :: [model: String.t() | nil]

  @typedoc "Options for send_message: :channel"
  @type send_opts :: [channel: String.t()]

  @typedoc "Options for spawn_subagent: :name, :model, :thinking, :post_mode"
  @type subagent_opts :: [
          name: String.t(),
          model: String.t() | nil,
          thinking: String.t(),
          post_mode: String.t()
        ]

  @typedoc "Work result with ticket info"
  @type work_result :: %{ticket_id: String.t(), output: String.t()}

  @typedoc "Subagent spawn result"
  @type subagent_result :: %{
          optional(:job_id) => String.t(),
          optional(:name) => String.t(),
          optional(:response) => map(),
          optional(:output) => String.t()
        }

  @doc """
  Send a work request to OpenClaw to spawn a coding agent for a ticket.

  Options:
  - :ticket_id - Linear ticket ID (e.g., "COR-123")
  - :details - Ticket description/details
  - :model - Model to use for the sub-agent (e.g., "anthropic/claude-opus-4-5")
  """
  @spec work_on_ticket(String.t(), String.t() | nil, work_opts()) ::
          {:ok, work_result()} | {:error, String.t()}
  def work_on_ticket(ticket_id, details, opts \\ []) do
    model = Keyword.get(opts, :model, nil)

    # Build the message for the agent
    message = build_work_message(ticket_id, details, model)

    # Run openclaw agent command
    args = [
      "agent",
      "--message",
      message,
      "--deliver",
      "--channel",
      "webchat"
    ]

    Logger.info(
      "[OpenClawClient] Sending work request for #{ticket_id} with model: #{model || "default"}"
    )

    case CommandRunner.run("openclaw", args, timeout: 30_000, stderr_to_stdout: true) do
      {:ok, output} ->
        Logger.info("[OpenClawClient] Success: #{String.slice(output, 0, 200)}")
        {:ok, %{ticket_id: ticket_id, output: output}}

      {:error, :timeout} ->
        Logger.error("[OpenClawClient] Command timed out after 30s")
        {:error, "openclaw agent timed out"}

      {:error, {:exit, code, output}} ->
        Logger.error("[OpenClawClient] Command failed (#{code}): #{output}")
        {:error, "openclaw agent failed: #{output}"}

      {:error, reason} ->
        Logger.error("[OpenClawClient] Command error: #{inspect(reason)}")
        {:error, "openclaw agent failed: #{format_error(reason)}"}
    end
  rescue
    e ->
      Logger.error("[OpenClawClient] Exception: #{Exception.message(e)}")
      {:error, "openclaw agent exception: #{Exception.message(e)}"}
  end

  @doc """
  Send a raw message to the OpenClaw main session.
  """
  @spec send_message(String.t(), send_opts()) :: {:ok, :sent}
  def send_message(message, opts \\ []) do
    channel = Keyword.get(opts, :channel, "webchat")

    args = [
      "agent",
      "--agent",
      "main",
      "--message",
      message,
      "--deliver",
      "--channel",
      channel
    ]

    Logger.info("[OpenClawClient] Sending message (async): #{String.slice(message, 0, 100)}...")

    # Fire and forget - don't block waiting for agent response
    # Use supervised task to prevent silent crashes and enable resource control
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        case CommandRunner.run("openclaw", args, timeout: 30_000, stderr_to_stdout: true) do
          {:ok, _output} ->
            Logger.info("[OpenClawClient] Message delivered successfully")

          {:error, :timeout} ->
            Logger.error("[OpenClawClient] Message delivery timed out after 30s")

          {:error, {:exit, code, output}} ->
            Logger.error("[OpenClawClient] Command failed (#{code}): #{output}")

          {:error, reason} ->
            Logger.error("[OpenClawClient] Command error: #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.error("[OpenClawClient] Task crashed: #{Exception.message(e)}")

          Logger.error(
            "[OpenClawClient] Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}"
          )
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
  """
  @spec spawn_subagent(String.t(), subagent_opts()) ::
          {:ok, subagent_result()} | {:error, String.t()}
  def spawn_subagent(task_message, opts \\ []) do
    name = Keyword.get(opts, :name, "task-#{:rand.uniform(999_999)}")
    model = Keyword.get(opts, :model)
    thinking = Keyword.get(opts, :thinking, "low")
    post_mode = Keyword.get(opts, :post_mode, "summary")

    # Build the cron add command
    args = [
      "cron",
      "add",
      "--name",
      "dashboard-#{name}",
      "--session",
      "isolated",
      # Schedule for 1 minute (minimum supported)
      "--at",
      "1m",
      # Auto-cleanup after completion
      "--delete-after-run",
      # Run immediately, don't wait for heartbeat
      "--wake",
      "now",
      "--message",
      task_message,
      "--thinking",
      thinking,
      "--post-mode",
      post_mode,
      "--json"
    ]

    # Add model if specified
    args = if model, do: args ++ ["--model", model], else: args

    Logger.info("[OpenClawClient] Spawning isolated sub-agent: dashboard-#{name}")

    case CommandRunner.run("openclaw", args, timeout: 30_000, stderr_to_stdout: true) do
      {:ok, output} ->
        # Try to find JSON in the output (might contain Node.js warnings)
        json_str = extract_json(output)

        case Jason.decode(json_str) do
          {:ok, %{"id" => job_id}} ->
            Logger.info("[OpenClawClient] Sub-agent spawned successfully: #{job_id}")
            {:ok, %{job_id: job_id, name: "dashboard-#{name}"}}

          {:ok, response} ->
            Logger.info("[OpenClawClient] Sub-agent spawned: #{inspect(response)}")
            {:ok, %{name: "dashboard-#{name}", response: response}}

          {:error, _} ->
            Logger.warning(
              "[OpenClawClient] Sub-agent spawned but couldn't parse response: #{output}"
            )

            {:ok, %{name: "dashboard-#{name}", output: output}}
        end

      {:error, :timeout} ->
        Logger.error("[OpenClawClient] Spawn timed out after 30s")
        {:error, "openclaw cron add timed out"}

      {:error, {:exit, code, output}} ->
        Logger.error("[OpenClawClient] Spawn failed (#{code}): #{output}")
        {:error, "openclaw cron add failed: #{output}"}

      {:error, reason} ->
        Logger.error("[OpenClawClient] Spawn error: #{inspect(reason)}")
        {:error, "openclaw cron add failed: #{format_error(reason)}"}
    end
  rescue
    e ->
      Logger.error("[OpenClawClient] Exception spawning sub-agent: #{Exception.message(e)}")
      {:error, "openclaw cron add exception: #{Exception.message(e)}"}
  end

  # Format error reasons into human-readable strings
  @spec format_error(term()) :: String.t()
  defp format_error(%{reason: reason}) when is_atom(reason), do: to_string(reason)
  defp format_error(%{original: original}) when is_atom(original), do: to_string(original)
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  # Extract JSON part from a string that might contain warnings or other text
  defp extract_json(output) do
    case Regex.run(~r/\{.*\}/s, output) do
      [json] -> json
      nil -> output
    end
  end

  # Build the work message that tells the agent to spawn a coding sub-agent
  @spec build_work_message(String.t(), String.t() | nil, String.t() | nil) :: String.t()
  defp build_work_message(ticket_id, details, model) do
    model_instruction =
      if model do
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
