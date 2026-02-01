defmodule DashboardPhoenixWeb.HomeLive.WorkProgressBuilder do
  @moduledoc """
  Builds maps tracking work-in-progress for tickets, PRs, and Chainlink issues.

  This module analyzes enriched session data to determine which tickets, PRs,
  and Chainlink issues currently have active work sessions. The resulting maps
  are used by UI components to show work status indicators.

  ## Workflow

  1. Sessions are enriched with `SessionEnricher` (extracts ticket/PR IDs)
  2. This module filters active sessions and builds lookup maps
  3. UI components use maps to show "work in progress" badges

  ## Performance

  Uses pre-extracted ticket/PR data from enriched sessions, making lookups O(n)
  instead of O(n*m) if we ran regex on every access.
  """

  alias DashboardPhoenix.Status
  alias DashboardPhoenix.ChainlinkWorkTracker

  @typedoc "Work session info for tickets in progress"
  @type ticket_work_info :: %{
          required(:type) => :opencode | :subagent,
          required(:session_id) => String.t(),
          required(:status) => String.t(),
          optional(:slug) => String.t(),
          optional(:label) => String.t(),
          optional(:title) => String.t(),
          optional(:task_summary) => String.t()
        }

  @typedoc "Work session info for PRs in progress"
  @type pr_work_info :: %{
          required(:type) => :opencode | :subagent,
          required(:session_id) => String.t(),
          required(:status) => String.t(),
          optional(:slug) => String.t(),
          optional(:label) => String.t(),
          optional(:title) => String.t(),
          optional(:task_summary) => String.t()
        }

  @doc """
  Build map of ticket_id -> work session info from OpenCode and sub-agent sessions.

  Uses pre-extracted ticket IDs from enriched sessions (O(n) iteration).

  ## Examples

      iex> build_tickets_in_progress(opencode_sessions, agent_sessions)
      %{"COR-123" => %{type: :opencode, session_id: "abc", status: "active"}}
  """
  @spec build_tickets_in_progress(list(map()), list(map())) ::
          %{optional(String.t()) => ticket_work_info()}
  def build_tickets_in_progress(opencode_sessions, agent_sessions) do
    # Build from OpenCode sessions using pre-extracted ticket IDs
    opencode_work =
      opencode_sessions
      |> Enum.filter(fn session -> session.status in [Status.active(), Status.idle()] end)
      |> Enum.flat_map(fn session ->
        ticket_ids = Map.get(session, :extracted_tickets, [])

        Enum.map(ticket_ids, fn ticket_id ->
          {ticket_id,
           %{
             type: :opencode,
             slug: session.slug,
             session_id: session.id,
             status: session.status,
             title: session.title
           }}
        end)
      end)

    # Build from sub-agent sessions using pre-extracted ticket IDs
    subagent_work =
      agent_sessions
      |> Enum.filter(fn session -> session.status in [Status.running(), Status.idle()] end)
      |> Enum.flat_map(fn session ->
        ticket_ids = Map.get(session, :extracted_tickets, [])

        Enum.map(ticket_ids, fn ticket_id ->
          {ticket_id,
           %{
             type: :subagent,
             label: Map.get(session, :label),
             session_id: session.id,
             status: session.status,
             task_summary: Map.get(session, :task_summary)
           }}
        end)
      end)

    # Combine - OpenCode takes precedence if both are working on same ticket
    Map.new(subagent_work ++ opencode_work)
  end

  @doc """
  Build map of PR number -> work session info from OpenCode and sub-agent sessions.

  Uses pre-extracted PR numbers from enriched sessions (O(n) iteration).
  Matches PR numbers like #123, PR-123, pr-244, fix-pr-244.

  ## Examples

      iex> build_prs_in_progress(opencode_sessions, agent_sessions)
      %{123 => %{type: :subagent, session_id: "xyz", status: "running"}}
  """
  @spec build_prs_in_progress(list(map()), list(map())) ::
          %{optional(pos_integer()) => pr_work_info()}
  def build_prs_in_progress(opencode_sessions, agent_sessions) do
    # Build from OpenCode sessions using pre-extracted PR numbers
    opencode_work =
      opencode_sessions
      |> Enum.filter(fn session -> session.status in [Status.active(), Status.idle()] end)
      |> Enum.flat_map(fn session ->
        pr_numbers = Map.get(session, :extracted_prs, [])

        Enum.map(pr_numbers, fn pr_number ->
          {pr_number,
           %{
             type: :opencode,
             slug: session.slug,
             session_id: session.id,
             status: session.status,
             title: session.title
           }}
        end)
      end)

    # Build from sub-agent sessions using pre-extracted PR numbers
    subagent_work =
      agent_sessions
      |> Enum.filter(fn session -> session.status in [Status.running(), Status.idle()] end)
      |> Enum.flat_map(fn session ->
        pr_numbers = Map.get(session, :extracted_prs, [])

        Enum.map(pr_numbers, fn pr_number ->
          {pr_number,
           %{
             type: :subagent,
             label: Map.get(session, :label),
             session_id: session.id,
             status: session.status,
             task_summary: Map.get(session, :task_summary)
           }}
        end)
      end)

    # Combine - OpenCode takes precedence if both are working on same PR
    Map.new(subagent_work ++ opencode_work)
  end

  @doc """
  Build map of chainlink issue_id -> work session info from sub-agent sessions.

  Looks for sessions with labels containing "ticket-" to detect active chainlink work.
  Merges with persisted work from ChainlinkWorkTracker and existing manually started work.

  ## Examples

      iex> build_chainlink_work_in_progress(agent_sessions, current_work)
      %{123 => %{type: :subagent, label: "ticket-123", session_id: "abc"}}
  """
  @spec build_chainlink_work_in_progress(list(map()), %{optional(integer()) => map()}) ::
          %{optional(integer()) => map()}
  def build_chainlink_work_in_progress(agent_sessions, current_work) do
    # Get active session IDs for cleanup
    active_session_ids =
      agent_sessions
      |> Enum.filter(fn session -> session.status in [Status.running(), Status.idle()] end)
      |> Enum.map(& &1.id)

    # Async sync with tracker to clean up stale persisted entries
    spawn(fn ->
      try do
        ChainlinkWorkTracker.sync_with_sessions(active_session_ids)
      rescue
        _ -> :ok
      end
    end)

    # Detect work from running sessions
    detected_work =
      agent_sessions
      |> Enum.filter(fn session -> session.status in [Status.running(), Status.idle()] end)
      |> Enum.filter(fn session ->
        label = Map.get(session, :label, "")
        String.contains?(label, "ticket-")
      end)
      |> Enum.map(fn session ->
        label = Map.get(session, :label, "")
        # Extract issue ID from label like "ticket-123", "fix-work-indicator-ticket-456", etc.
        case Regex.run(~r/ticket-(\d+)/, label) do
          [_, issue_id_str] ->
            case Integer.parse(issue_id_str) do
              {issue_id, ""} ->
                {issue_id,
                 %{
                   type: :subagent,
                   label: label,
                   session_id: session.id,
                   status: session.status,
                   task_summary: Map.get(session, :task_summary)
                 }}

              _ ->
                nil
            end

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    # Load persisted work from tracker
    persisted_work = load_persisted_chainlink_work()

    # Merge: persisted -> current -> detected (later takes precedence)
    persisted_work
    |> Map.merge(current_work)
    |> Map.merge(detected_work)
  end

  @doc """
  Load persisted work from the ChainlinkWorkTracker.
  """
  @spec load_persisted_chainlink_work() :: %{optional(integer()) => map()}
  def load_persisted_chainlink_work do
    try do
      ChainlinkWorkTracker.get_all_work()
    rescue
      _ -> %{}
    catch
      :exit, _ -> %{}
    end
  end
end
