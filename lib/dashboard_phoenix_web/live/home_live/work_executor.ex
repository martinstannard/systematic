defmodule DashboardPhoenixWeb.HomeLive.WorkExecutor do
  @moduledoc """
  Handles spawning work on different coding agents (Claude, OpenCode, Gemini).

  This module encapsulates the logic for:
  - Building work prompts from ticket/issue details
  - Spawning work on the appropriate agent based on configuration
  - Registering work with the WorkRegistry
  - Logging activity events

  Used by HomeLive when executing work from the work modal or Chainlink panel.
  """

  alias DashboardPhoenix.ActivityLog
  alias DashboardPhoenix.ClientFactory
  alias DashboardPhoenix.GeminiServer
  alias DashboardPhoenix.Models
  alias DashboardPhoenix.WorkRegistry
  alias DashboardPhoenix.WorkSpawner
  alias DashboardPhoenix.ChainlinkWorkTracker

  @typedoc "Result of spawning work"
  @type spawn_result ::
          {:ok, %{session_id: String.t()}}
          | {:ok, %{ticket_id: String.t()}}
          | {:ok, %{job_id: String.t()}}
          | {:error, term()}

  @typedoc "Agent type for work execution"
  @type agent_type :: :claude | :opencode | :gemini

  @doc """
  Execute work for a Linear ticket.

  Spawns work on the appropriate agent based on coding_pref.
  Returns immediately with the work spawned in a background task.

  ## Options
    * `:coding_pref` - Which agent to use (:claude, :opencode, :gemini)
    * `:claude_model` - Model to use for Claude
    * `:opencode_model` - Model to use for OpenCode
    * `:callback_pid` - PID to send {:work_result, result} when done
  """
  @spec execute_linear_work(String.t(), String.t() | nil, keyword()) :: :ok
  def execute_linear_work(ticket_id, ticket_details, opts) do
    coding_pref = Keyword.fetch!(opts, :coding_pref)
    claude_model = Keyword.get(opts, :claude_model, Models.default_claude_model())
    opencode_model = Keyword.get(opts, :opencode_model, Models.default_opencode_model())
    callback_pid = Keyword.get(opts, :callback_pid)

    # Determine agent type and model
    {agent_type, model} =
      case coding_pref do
        :opencode -> {:opencode, opencode_model}
        :gemini -> {:gemini, Models.gemini_2_flash()}
        _ -> {:claude, claude_model}
      end

    ActivityLog.log_event(:task_started, "Work started on #{ticket_id}", %{
      ticket_id: ticket_id,
      agent: to_string(agent_type),
      model: model
    })

    # Gemini needs special handling via GeminiServer
    if coding_pref == :gemini do
      prompt = build_ticket_prompt(ticket_id, ticket_details)
      execute_gemini_work(ticket_id, prompt, callback_pid)
    else
      # Claude and OpenCode go through WorkSpawner
      Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
        result =
          WorkSpawner.spawn_linear(
            ticket_id,
            "Linear: #{ticket_id}",
            ticket_details || "No details available",
            agent_type: agent_type,
            model: model
          )

        if callback_pid, do: send(callback_pid, {:work_result, result})
      end)
    end

    :ok
  end

  @doc """
  Execute work for a Chainlink issue.

  Spawns work on the appropriate agent based on coding_pref.

  ## Options
    * `:coding_pref` - Which agent to use (:claude, :opencode, :gemini)
    * `:claude_model` - Model to use for Claude
    * `:opencode_model` - Model to use for OpenCode
  """
  @spec execute_chainlink_work(map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_chainlink_work(issue, opts) do
    coding_pref = Keyword.fetch!(opts, :coding_pref)
    claude_model = Keyword.get(opts, :claude_model, Models.default_claude_model())
    opencode_model = Keyword.get(opts, :opencode_model, Models.default_opencode_model())

    prompt = build_chainlink_prompt(issue)

    case coding_pref do
      :opencode ->
        spawn_opencode_chainlink_work(issue, prompt, opencode_model)

      :gemini ->
        spawn_gemini_chainlink_work(issue, prompt)

      _ ->
        spawn_claude_chainlink_work(issue, prompt, claude_model)
    end
  end

  @doc """
  Execute work for fixing PR issues (conflicts, CI failures).

  Always spawns a Claude sub-agent for PR fix work.
  """
  @spec execute_pr_fix(map()) :: {:ok, map()} | {:error, term()}
  def execute_pr_fix(%{
        "url" => pr_url,
        "number" => pr_number,
        "repo" => repo,
        "branch" => branch,
        "has_conflicts" => has_conflicts,
        "ci_failing" => ci_failing
      }) do
    issues = []
    issues = if ci_failing, do: ["CI failures" | issues], else: issues
    issues = if has_conflicts, do: ["merge conflicts" | issues], else: issues
    issues_text = Enum.join(issues, " and ")

    prompt =
      build_pr_fix_prompt(pr_url, pr_number, repo, branch, has_conflicts, ci_failing, issues_text)

    ClientFactory.openclaw_client().spawn_subagent(prompt,
      name: "pr-fix-#{pr_number}",
      thinking: "low",
      post_mode: "summary"
    )
  end

  @doc """
  Execute a super review for a ticket or PR.
  """
  @spec execute_super_review(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_super_review(target_id, opts) do
    type = Keyword.get(opts, :type, :ticket)

    prompt =
      case type do
        :pr -> build_pr_review_prompt(target_id, Keyword.get(opts, :repo))
        :ticket -> build_ticket_review_prompt(target_id)
      end

    ClientFactory.openclaw_client().spawn_subagent(prompt,
      name: "review-#{target_id}",
      thinking: "medium",
      post_mode: "summary"
    )
  end

  # ============================================================================
  # Private - Work Spawning
  # ============================================================================

  defp spawn_opencode_chainlink_work(issue, prompt, model) do
    issue_id = issue.id

    case ClientFactory.opencode_client().send_task(prompt, model: model) do
      {:ok, _result} ->
        work_info = %{
          label: "chainlink-#{issue_id}",
          agent_type: "opencode",
          model: model,
          started_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        ChainlinkWorkTracker.start_work(issue_id, work_info)

        ActivityLog.log_event(:task_started, "Work started on Chainlink ##{issue_id}", %{
          issue_id: issue_id,
          title: issue.title,
          priority: issue.priority,
          agent: "opencode",
          model: model
        })

        {:ok, work_info}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp spawn_gemini_chainlink_work(issue, prompt) do
    issue_id = issue.id

    if GeminiServer.running?() do
      case GeminiServer.send_prompt(prompt) do
        :ok ->
          work_info = %{
            label: "chainlink-#{issue_id}",
            agent_type: "gemini",
            model: "gemini-2.0-flash",
            started_at: DateTime.utc_now() |> DateTime.to_iso8601()
          }

          ChainlinkWorkTracker.start_work(issue_id, work_info)

          ActivityLog.log_event(:task_started, "Work started on Chainlink ##{issue_id}", %{
            issue_id: issue_id,
            title: issue.title,
            priority: issue.priority,
            agent: "gemini",
            model: "gemini-2.0-flash"
          })

          {:ok, work_info}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "Gemini server not running"}
    end
  end

  defp spawn_claude_chainlink_work(issue, prompt, model) do
    issue_id = issue.id

    case ClientFactory.openclaw_client().spawn_subagent(prompt,
           name: "chainlink-#{issue_id}",
           thinking: "low",
           post_mode: "summary",
           model: model
         ) do
      {:ok, result} ->
        job_id = Map.get(result, :job_id, "unknown")
        name = Map.get(result, :name, "chainlink-#{issue_id}")

        work_info = %{
          label: name,
          job_id: job_id,
          agent_type: "claude",
          model: model,
          started_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        ChainlinkWorkTracker.start_work(issue_id, work_info)

        ActivityLog.log_event(:task_started, "Work started on Chainlink ##{issue_id}", %{
          issue_id: issue_id,
          title: issue.title,
          priority: issue.priority,
          agent: "claude",
          model: model
        })

        {:ok, work_info}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_gemini_work(ticket_id, prompt, callback_pid) do
    # Register with WorkRegistry first
    {:ok, work_id} =
      WorkRegistry.register(%{
        agent_type: :gemini,
        ticket_id: ticket_id,
        source: :linear,
        description: "Linear: #{ticket_id}",
        model: Models.gemini_2_flash()
      })

    if GeminiServer.running?() do
      case GeminiServer.send_prompt(prompt) do
        :ok ->
          if callback_pid do
            send(callback_pid, {:work_result, {:ok, %{ticket_id: ticket_id}}})
          end

        {:error, reason} ->
          WorkRegistry.fail(work_id, inspect(reason))

          if callback_pid do
            send(callback_pid, {:work_result, {:error, reason}})
          end
      end
    else
      # Start Gemini server first, then send prompt
      case GeminiServer.start_server() do
        {:ok, _pid} ->
          Process.sleep(2000)

          case GeminiServer.send_prompt(prompt) do
            :ok ->
              if callback_pid do
                send(callback_pid, {:work_result, {:ok, %{ticket_id: ticket_id}}})
              end

            {:error, reason} ->
              WorkRegistry.fail(work_id, inspect(reason))

              if callback_pid do
                send(callback_pid, {:work_result, {:error, reason}})
              end
          end

        {:error, reason} ->
          WorkRegistry.fail(work_id, inspect(reason))

          if callback_pid do
            send(callback_pid, {:work_result, {:error, reason}})
          end
      end
    end
  end

  # ============================================================================
  # Private - Prompt Building
  # ============================================================================

  defp build_ticket_prompt(ticket_id, ticket_details) do
    """
    Work on ticket #{ticket_id}.

    Ticket details:
    #{ticket_details || "No details available - use the ticket ID to look it up."}

    Please analyze this ticket and implement the required changes.
    """
  end

  defp build_chainlink_prompt(issue) do
    """
    Work on Chainlink issue ##{issue.id}: #{issue.title}

    Priority: #{issue.priority}

    Please analyze this issue and implement the required changes.
    Use `chainlink show #{issue.id}` to get full details.
    """
  end

  defp build_pr_fix_prompt(
         pr_url,
         pr_number,
         repo,
         branch,
         has_conflicts,
         ci_failing,
         issues_text
       ) do
    alias DashboardPhoenix.Paths

    """
    🔧 **Fix #{issues_text} for PR ##{pr_number}**

    This Pull Request has #{issues_text}. Please fix them:
    URL: #{pr_url}
    Repository: #{repo}
    Branch: #{branch}

    Steps:
    1. First, check out the branch: `cd #{Paths.core_platform_repo()} && git fetch origin && git checkout #{branch}`
    #{if has_conflicts, do: "2. Resolve merge conflicts: `git fetch origin main && git merge origin/main` - fix any conflicts, then commit", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "3", else: "2"}. Get CI failure details: `gh pr checks #{pr_number} --repo #{repo}`", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "4", else: "3"}. Review the failing checks and fix the issues (tests, linting, type errors, etc.)", else: ""}
    #{if ci_failing, do: "#{if has_conflicts, do: "5", else: "4"}. Run tests locally to verify: `mix test`", else: ""}
    - Commit and push the fixes

    Focus on fixing the issues, not refactoring unrelated code.
    """
  end

  defp build_pr_review_prompt(pr_number, repo) do
    """
    🔍 **Super Review Request for PR ##{pr_number}**

    Please perform a comprehensive code review for this Pull Request:
    Repository: #{repo}

    1. Fetch and review the PR using `gh pr view #{pr_number} --repo #{repo}`
    2. Review the diff using `gh pr diff #{pr_number} --repo #{repo}`
    3. Check all code changes for:
       - Code quality and best practices
       - Potential bugs or edge cases
       - Performance implications
       - Security concerns
       - Test coverage
    4. Leave detailed review comments on the PR
    5. Approve or request changes as appropriate using `gh pr review`

    Be thorough but constructive in your feedback.
    """
  end

  defp build_ticket_review_prompt(ticket_id) do
    """
    🔍 **Super Review Request for #{ticket_id}**

    Please perform a comprehensive code review for the PR related to ticket #{ticket_id}:

    1. Check out the PR branch
    2. Review all code changes for:
       - Code quality and best practices
       - Potential bugs or edge cases
       - Performance implications
       - Security concerns
       - Test coverage
    3. Verify the implementation matches the ticket requirements
    4. Leave detailed review comments on the PR
    5. Approve or request changes as appropriate

    Use `gh pr view` to find the PR and `gh pr diff` to see changes.
    """
  end
end
