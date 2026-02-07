defmodule DashboardPhoenix.WorkSpawner do
  @moduledoc """
  Unified work spawner that goes through WorkRegistry.

  All agent spawning should go through this module to ensure
  proper tracking and metadata storage.

  ## Error Handling

  When spawns fail, detailed error information is stored in WorkRegistry including:
  - Error type (connection_error, timeout, spawn_failed, etc.)
  - Human-readable message
  - Technical details for debugging
  - Timestamp of failure

  Use `WorkRegistry.recent_failures/1` to retrieve recent failures for dashboard display.
  """

  alias DashboardPhoenix.WorkRegistry
  alias DashboardPhoenix.ClientFactory
  require Logger

  @typedoc "Detailed error info for spawn failures"
  @type spawn_error :: %{
          type: atom(),
          message: String.t(),
          details: String.t() | nil,
          agent_type: atom(),
          recoverable: boolean()
        }

  @doc """
  Spawn work with the specified agent type.

  Returns {:ok, work_id} or {:error, reason}.

  Options:
  - :ticket_id - chainlink or linear ticket ID
  - :source - :chainlink | :linear | :pr_fix | :dashboard | :manual
  - :description - task description
  - :model - model to use (defaults based on agent type)
  - :label - session label
  - :prompt - the actual prompt/task message
  - :thinking - thinking level for Claude (default: "low")
  """
  def spawn(agent_type, opts \\ []) do
    prompt = Keyword.fetch!(opts, :prompt)

    # Register work first
    work_attrs = %{
      agent_type: agent_type,
      ticket_id: Keyword.get(opts, :ticket_id),
      source: Keyword.get(opts, :source, :manual),
      description: Keyword.get(opts, :description, extract_description(prompt)),
      model: Keyword.get(opts, :model),
      label: Keyword.get(opts, :label)
    }

    case WorkRegistry.register(work_attrs) do
      {:ok, work_id} ->
        # Now spawn the actual agent
        result = do_spawn(agent_type, work_id, opts)

        case result do
          {:ok, session_id} ->
            WorkRegistry.update(work_id, %{session_id: session_id})
            {:ok, work_id}

          {:error, reason} ->
            error_info = format_spawn_error(agent_type, reason)
            WorkRegistry.fail(work_id, error_info)
            Logger.warning("[WorkSpawner] Spawn failed for #{agent_type}: #{error_info}")
            {:error, reason}
        end

      {:error, reason} = error ->
        Logger.error("[WorkSpawner] Failed to register work: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Format a spawn error into a detailed, human-readable string.

  Returns a string with error type, message, and details for storage in WorkRegistry.
  """
  @spec format_spawn_error(atom(), term()) :: String.t()
  def format_spawn_error(agent_type, reason) do
    {error_type, message, details} = classify_error(agent_type, reason)

    base = "[#{error_type}] #{message}"
    if details, do: "#{base} | #{details}", else: base
  end

  # Classify errors by type for better user feedback
  defp classify_error(agent_type, reason) do
    case reason do
      # Connection errors
      {:error, :econnrefused} ->
        {:connection_error, "#{agent_name(agent_type)} server not reachable",
         "Connection refused - is the server running?"}

      {:error, :timeout} ->
        {:timeout, "Request to #{agent_name(agent_type)} timed out",
         "Server may be overloaded or unresponsive"}

      {:error, :nxdomain} ->
        {:connection_error, "DNS lookup failed for #{agent_name(agent_type)}",
         "Check network configuration"}

      # HTTP errors
      {:error, %{status: status}} when status >= 500 ->
        {:server_error, "#{agent_name(agent_type)} server error (#{status})",
         "Server returned an error"}

      {:error, %{status: 401}} ->
        {:auth_error, "Authentication failed for #{agent_name(agent_type)}",
         "Check API credentials"}

      {:error, %{status: 403}} ->
        {:auth_error, "Access denied to #{agent_name(agent_type)}", "Insufficient permissions"}

      {:error, %{status: 429}} ->
        {:rate_limit, "Rate limited by #{agent_name(agent_type)}",
         "Too many requests - try again later"}

      {:error, %{status: status, body: body}} ->
        {:api_error, "#{agent_name(agent_type)} API error (#{status})", truncate(body, 100)}

      # Process/system errors
      {:error, {:exit, exit_reason}} ->
        {:process_error, "#{agent_name(agent_type)} process crashed", inspect(exit_reason)}

      # Gemini CLI errors
      "Gemini failed (code " <> _ = msg ->
        {:spawn_failed, "Gemini CLI execution failed", msg}

      # Unknown agent type
      "Unknown agent type: " <> type ->
        {:invalid_config, "Unknown agent type", type}

      # Generic errors
      {:error, msg} when is_binary(msg) ->
        {:spawn_failed, "Failed to spawn #{agent_name(agent_type)}", truncate(msg, 100)}

      other ->
        {:unknown_error, "Unexpected error spawning #{agent_name(agent_type)}",
         truncate(inspect(other), 150)}
    end
  end

  defp agent_name(:claude), do: "Claude"
  defp agent_name(:opencode), do: "OpenCode"
  defp agent_name(:gemini), do: "Gemini"
  defp agent_name(other), do: to_string(other)

  defp truncate(str, max_len) when is_binary(str) do
    if String.length(str) > max_len do
      String.slice(str, 0, max_len) <> "..."
    else
      str
    end
  end

  defp truncate(other, max_len), do: truncate(inspect(other), max_len)

  @doc """
  Spawn work using the least busy agent (round-robin).
  """
  def spawn_balanced(opts \\ []) do
    agent_type = WorkRegistry.least_busy_agent()
    Logger.info("[WorkSpawner] Balanced spawn selected: #{agent_type}")
    spawn(agent_type, opts)
  end

  @doc """
  Spawn work for a chainlink ticket.
  """
  def spawn_chainlink(ticket_id, title, opts \\ []) do
    agent_type = Keyword.get(opts, :agent_type) || WorkRegistry.least_busy_agent()
    model = Keyword.get(opts, :model)

    prompt = """
    Work on Chainlink issue ##{ticket_id}: #{title}

    Please analyze this issue and implement the required changes.
    Use `chainlink show #{ticket_id}` to get full details.

    Follow the worktree workflow:
    1. cd ~/code/systematic
    2. git fetch origin
    3. git worktree add ../systematic-ticket-#{ticket_id} -b ticket-#{ticket_id} main
    4. cd ../systematic-ticket-#{ticket_id}
    5. Do the work
    6. Run tests: mix test
    7. Commit with detailed message
    8. Merge back: cd ~/code/systematic && git merge ticket-#{ticket_id}
    9. Remove worktree: git worktree remove ../systematic-ticket-#{ticket_id}

    Update chainlink when done: chainlink close #{ticket_id}
    """

    spawn(
      agent_type,
      [
        prompt: prompt,
        ticket_id: ticket_id,
        source: :chainlink,
        description: title,
        model: model,
        label: "ticket-#{ticket_id}-#{slugify(title)}"
      ] ++ opts
    )
  end

  @doc """
  Spawn work for a Linear ticket.
  """
  def spawn_linear(ticket_id, title, details, opts \\ []) do
    agent_type = Keyword.get(opts, :agent_type, :claude)
    model = Keyword.get(opts, :model)

    prompt = """
    Work on Linear ticket #{ticket_id}: #{title}

    Details:
    #{details}

    Follow standard development workflow with tests and commits.
    """

    spawn(
      agent_type,
      [
        prompt: prompt,
        ticket_id: ticket_id,
        source: :linear,
        description: title,
        model: model,
        label: "#{ticket_id}-#{slugify(title)}"
      ] ++ opts
    )
  end

  @doc """
  Spawn work to fix PR issues.
  """
  def spawn_pr_fix(pr_number, repo, issues_description, opts \\ []) do
    agent_type = Keyword.get(opts, :agent_type, :claude)
    model = Keyword.get(opts, :model)

    prompt = """
    Fix issues on PR ##{pr_number} in #{repo}:

    #{issues_description}

    Check out the PR branch, fix the issues, and push.
    """

    spawn(
      agent_type,
      [
        prompt: prompt,
        source: :pr_fix,
        description: "Fix PR ##{pr_number}",
        model: model,
        label: "pr-fix-#{pr_number}"
      ] ++ opts
    )
  end

  # Private functions

  defp do_spawn(:claude, work_id, opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    label = Keyword.get(opts, :label, "work-#{work_id}")
    model = Keyword.get(opts, :model)
    thinking = Keyword.get(opts, :thinking, "low")

    spawn_opts = [
      name: label,
      thinking: thinking,
      post_mode: "summary"
    ]

    spawn_opts = if model, do: Keyword.put(spawn_opts, :model, model), else: spawn_opts

    case ClientFactory.openclaw_client().spawn_subagent(prompt, spawn_opts) do
      {:ok, result} ->
        session_id = Map.get(result, :job_id, work_id)
        {:ok, session_id}

      error ->
        error
    end
  end

  defp do_spawn(:opencode, work_id, opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    model = Keyword.get(opts, :model)

    case ClientFactory.opencode_client().send_task(prompt, model: model) do
      {:ok, result} ->
        session_id = Map.get(result, :session_id) || work_id
        {:ok, session_id}

      error ->
        error
    end
  end

  defp do_spawn(:gemini, work_id, opts) do
    prompt = Keyword.fetch!(opts, :prompt)

    # Gemini spawns via CLI in background
    escaped_prompt = prompt |> String.replace("\"", "\\\"") |> String.replace("\n", " ")
    cmd = "cd ~/code/systematic && gemini -p \"#{escaped_prompt}\" &"

    case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
      {_output, 0} ->
        # Gemini doesn't give us a session ID
        {:ok, work_id}

      {output, code} ->
        {:error, "Gemini failed (code #{code}): #{output}"}
    end
  end

  defp do_spawn(unknown, _work_id, _opts) do
    {:error, "Unknown agent type: #{unknown}"}
  end

  defp extract_description(prompt) do
    prompt
    |> String.split("\n")
    |> Enum.find(&(&1 != ""))
    |> String.slice(0, 100)
  end

  defp slugify(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.slice(0, 30)
    |> String.trim("-")
  end
end
