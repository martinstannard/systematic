defmodule DashboardPhoenix.PanelStatus do
  @moduledoc """
  Utilities for determining panel status indicators and visual classes
  based on panel data and state.
  """

  alias DashboardPhoenix.Status

  @doc """
  Determines the status class for a panel based on its content and state.
  Returns a string with space-separated CSS classes.
  """
  def status_classes(panel_type, data, opts \\ [])

  # Linear tickets panel status
  def status_classes(:linear, %{error: error, loading: loading, tickets: tickets}, _opts) do
    cond do
      error != nil -> "panel-status-error"
      loading -> "panel-status-loading"
      has_overdue_tickets?(tickets) -> "panel-status-urgent"
      has_high_priority_tickets?(tickets) -> "panel-status-warning"
      has_active_work?(tickets) -> "panel-status-working"
      Enum.empty?(tickets) -> "panel-status-idle"
      true -> ""
    end
  end

  # Chainlink issues panel status
  def status_classes(:chainlink, %{error: error, loading: loading, issues: issues, work_in_progress: wip}, _opts) do
    cond do
      error != nil -> "panel-status-error"
      loading -> "panel-status-loading"
      has_high_priority_issues?(issues) -> "panel-status-urgent"
      has_active_chainlink_work?(wip) -> "panel-status-working"
      Enum.empty?(issues) -> "panel-status-idle"
      true -> ""
    end
  end

  # GitHub PRs panel status
  def status_classes(:github_prs, %{error: error, loading: loading, prs: prs, verifications: verifications}, _opts) do
    cond do
      error != nil -> "panel-status-error"
      loading -> "panel-status-loading"
      has_failing_prs?(prs, verifications) -> "panel-status-error"
      has_conflicts_or_ci_failures?(prs) -> "panel-status-warning"
      has_ready_to_merge_prs?(prs) -> "panel-status-success"
      has_draft_prs?(prs) -> "panel-status-working"
      Enum.empty?(prs) -> "panel-status-idle"
      true -> ""
    end
  end

  # Branches panel status
  def status_classes(:branches, %{error: error, loading: loading, branches: branches}, _opts) do
    cond do
      error != nil -> "panel-status-error"
      loading -> "panel-status-loading"
      has_stale_branches?(branches) -> "panel-status-warning"
      has_recent_branches?(branches) -> "panel-status-working"
      Enum.empty?(branches) -> "panel-status-idle"
      true -> ""
    end
  end

  # OpenCode sessions panel status
  def status_classes(:opencode, %{server_status: server, sessions: sessions}, _opts) do
    cond do
      not server.running -> "panel-status-idle"
      has_error_sessions?(sessions) -> "panel-status-error"
      has_active_sessions?(sessions) -> "panel-status-working"
      Enum.empty?(sessions) -> "panel-status-success"
      true -> ""
    end
  end

  # Gemini server panel status
  def status_classes(:gemini, %{server_status: server, output: output}, _opts) do
    cond do
      not server.running -> "panel-status-idle"
      has_error_output?(output) -> "panel-status-error"
      server.running and String.length(output || "") > 0 -> "panel-status-working"
      server.running -> "panel-status-success"
      true -> ""
    end
  end

  # Sub-agents panel status
  def status_classes(:subagents, %{sessions: sessions}, _opts) do
    failed_count = count_failed_sessions(sessions)
    active_count = count_active_sessions(sessions)
    
    cond do
      failed_count > 0 -> "panel-status-error"
      active_count > 3 -> "panel-status-warning"
      active_count > 0 -> "panel-status-working"
      true -> "panel-status-idle"
    end
  end

  # System processes panel status
  def status_classes(:system_processes, %{agents: agents, processes: processes}, _opts) do
    failed_agents = count_failed_agents(agents)
    high_memory_processes = count_high_memory_processes(processes)
    
    cond do
      failed_agents > 0 -> "panel-status-error"
      high_memory_processes > 2 -> "panel-status-warning"
      length(agents) > 0 -> "panel-status-working"
      true -> "panel-status-idle"
    end
  end

  # Usage stats panel status
  def status_classes(:usage_stats, %{opencode: opencode_stats, claude: claude_stats}, _opts) do
    cond do
      is_high_usage?(opencode_stats) or is_high_usage?(claude_stats) -> "panel-status-warning"
      has_recent_usage?(opencode_stats) or has_recent_usage?(claude_stats) -> "panel-status-working"
      true -> "panel-status-idle"
    end
  end

  # Default case
  def status_classes(_panel_type, _data, _opts), do: ""

  @doc """
  Returns attention badge class if the panel needs user attention.
  """
  def attention_badge(panel_type, data, opts \\ [])

  def attention_badge(:linear, %{tickets: tickets}, _opts) do
    cond do
      has_overdue_tickets?(tickets) -> "panel-attention-error"
      has_high_priority_tickets?(tickets) -> "panel-attention-warning"
      true -> nil
    end
  end

  def attention_badge(:github_prs, %{prs: prs}, _opts) do
    cond do
      has_conflicts_or_ci_failures?(prs) -> "panel-attention-error"
      has_ready_to_merge_prs?(prs) -> "panel-attention-info"
      true -> nil
    end
  end

  def attention_badge(:chainlink, %{issues: issues}, _opts) do
    if has_high_priority_issues?(issues) do
      "panel-attention-warning"
    else
      nil
    end
  end

  def attention_badge(_panel_type, _data, _opts), do: nil

  # Private helper functions

  defp has_overdue_tickets?(tickets) when is_list(tickets) do
    Enum.any?(tickets, fn ticket ->
      ticket.status in ["Todo", "In Progress"] and 
      is_overdue?(ticket.due_date) and
      ticket.priority in ["High", "Urgent"]
    end)
  end

  defp has_overdue_tickets?(_), do: false

  defp has_high_priority_tickets?(tickets) when is_list(tickets) do
    Enum.any?(tickets, fn ticket ->
      ticket.priority in ["High", "Urgent"] and
      ticket.status in ["Todo", "In Progress"]
    end)
  end

  defp has_high_priority_tickets?(_), do: false

  defp has_active_work?(tickets) when is_list(tickets) do
    Enum.any?(tickets, fn ticket ->
      ticket.status == "In Progress"
    end)
  end

  defp has_active_work?(_), do: false

  defp has_high_priority_issues?(issues) when is_list(issues) do
    Enum.any?(issues, fn issue ->
      issue.priority in ["high", "urgent"]
    end)
  end

  defp has_high_priority_issues?(_), do: false

  defp has_active_chainlink_work?(wip) when is_map(wip) do
    map_size(wip) > 0
  end

  defp has_active_chainlink_work?(_), do: false

  defp has_failing_prs?(prs, verifications) when is_list(prs) and is_map(verifications) do
    Enum.any?(prs, fn pr ->
      verification = Map.get(verifications, pr.url, %{})
      verification[:status] == Status.failed()
    end)
  end

  defp has_failing_prs?(_, _), do: false

  defp has_conflicts_or_ci_failures?(prs) when is_list(prs) do
    Enum.any?(prs, fn pr ->
      # Use Map.get for defensive access - handle PRs without all fields
      mergeable = Map.get(pr, :mergeable)
      ci_status = Map.get(pr, :ci_status)
      has_conflicts = Map.get(pr, :has_conflicts, false)
      # Check for conflicts via either mergeable=false or has_conflicts=true
      has_conflicts or mergeable == false or ci_status in ["failure", Status.error(), :failure, :error]
    end)
  end

  defp has_conflicts_or_ci_failures?(_), do: false

  defp has_ready_to_merge_prs?(prs) when is_list(prs) do
    Enum.any?(prs, fn pr ->
      # Use Map.get for defensive access - handle PRs without all fields
      mergeable = Map.get(pr, :mergeable, true) # default true if not present
      ci_status = Map.get(pr, :ci_status)
      approved = Map.get(pr, :approved, false)
      review_status = Map.get(pr, :review_status)
      mergeable == true and ci_status in ["success", :success] and (approved == true or review_status == :approved)
    end)
  end

  defp has_ready_to_merge_prs?(_), do: false

  defp has_draft_prs?(prs) when is_list(prs) do
    Enum.any?(prs, fn pr ->
      pr.draft == true
    end)
  end

  defp has_draft_prs?(_), do: false

  defp has_stale_branches?(branches) when is_list(branches) do
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30 * 24 * 60 * 60, :second)
    
    Enum.any?(branches, fn branch ->
      case parse_date(branch.last_commit_date) do
        {:ok, date} -> DateTime.compare(date, thirty_days_ago) == :lt
        _ -> false
      end
    end)
  end

  defp has_stale_branches?(_), do: false

  defp has_recent_branches?(branches) when is_list(branches) do
    seven_days_ago = DateTime.utc_now() |> DateTime.add(-7 * 24 * 60 * 60, :second)
    
    Enum.any?(branches, fn branch ->
      case parse_date(branch.last_commit_date) do
        {:ok, date} -> DateTime.compare(date, seven_days_ago) == :gt
        _ -> false
      end
    end)
  end

  defp has_recent_branches?(_), do: false
  
  # Parse date that can be either a DateTime struct or an ISO 8601 string
  defp parse_date(%DateTime{} = date), do: {:ok, date}
  defp parse_date(date_string) when is_binary(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, date, _offset} -> {:ok, date}
      error -> error
    end
  end
  defp parse_date(_), do: :error

  defp has_error_sessions?(sessions) when is_list(sessions) do
    Enum.any?(sessions, fn session ->
      String.contains?(session.status || "", Status.error())
    end)
  end

  defp has_error_sessions?(_), do: false

  defp has_active_sessions?(sessions) when is_list(sessions) do
    Enum.any?(sessions, fn session ->
      session.status in Status.active_statuses()
    end)
  end

  defp has_active_sessions?(_), do: false

  defp has_error_output?(output) when is_binary(output) do
    String.contains?(String.downcase(output), [Status.error(), Status.failed(), "exception", "crash"])
  end

  defp has_error_output?(_), do: false

  defp count_failed_sessions(sessions) when is_list(sessions) do
    Enum.count(sessions, fn session ->
      session.status in Status.error_statuses()
    end)
  end

  defp count_failed_sessions(_), do: 0

  defp count_active_sessions(sessions) when is_list(sessions) do
    Enum.count(sessions, fn session ->
      session.status in [Status.running(), Status.active(), Status.busy(), Status.spawned()]
    end)
  end

  defp count_active_sessions(_), do: 0

  defp count_failed_agents(agents) when is_list(agents) do
    Enum.count(agents, fn agent ->
      agent.status in Status.error_statuses()
    end)
  end

  defp count_failed_agents(_), do: 0

  defp count_high_memory_processes(processes) when is_list(processes) do
    Enum.count(processes, fn process ->
      case process[:memory_mb] do
        memory when is_number(memory) -> memory > 500
        _ -> false
      end
    end)
  end

  defp count_high_memory_processes(_), do: 0

  defp is_high_usage?(stats) when is_map(stats) do
    # Check if daily usage is high (arbitrarily > 1000 tokens)
    daily_tokens = get_in(stats, [:daily, :total_tokens]) || 0
    daily_tokens > 1000
  end

  defp is_high_usage?(_), do: false

  defp has_recent_usage?(stats) when is_map(stats) do
    # Check if there's been usage in the last hour
    hourly_tokens = get_in(stats, [:hourly, :total_tokens]) || 0
    hourly_tokens > 0
  end

  defp has_recent_usage?(_), do: false

  defp is_overdue?(due_date) when is_binary(due_date) do
    case Date.from_iso8601(due_date) do
      {:ok, date} -> Date.compare(date, Date.utc_today()) == :lt
      _ -> false
    end
  end

  defp is_overdue?(_), do: false
end