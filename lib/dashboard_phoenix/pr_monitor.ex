defmodule DashboardPhoenix.PRMonitor do
  @moduledoc """
  Monitors GitHub Pull Requests by polling the GitHub CLI.
  Fetches open PRs with CI status, review status, and associated Linear tickets.
  """

  use GenServer
  require Logger

  alias DashboardPhoenix.{CommandRunner, CLITools}

  @poll_interval_ms 60_000  # 60 seconds
  @topic "pr_updates"
  @linear_workspace "fresh-clinics"  # Workspace slug for Linear URLs
  @repos ["Fresh-Clinics/core-platform"]  # Repos to monitor
  @cli_timeout_ms 60_000  # GitHub API can be slow

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all cached PRs"
  def get_prs do
    GenServer.call(__MODULE__, :get_prs)
  end

  @doc "Force refresh PRs from GitHub"
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Subscribe to PR updates"
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @topic)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Check tool availability on startup
    initial_error = case CLITools.check_tool("gh", "GitHub CLI") do
      {:ok, _path} ->
        Logger.info("PRMonitor initialized - GitHub CLI available")
        nil
      
      {:error, {reason, _name}} ->
        message = case reason do
          :not_found -> "GitHub CLI (gh) command not found in PATH. Install from https://cli.github.com/"
          :not_executable -> "GitHub CLI (gh) found but not executable"
          _ -> "GitHub CLI (gh) unavailable: #{reason}"
        end
        Logger.warning("PRMonitor starting with missing tools: #{message}")
        message
    end
    
    # Start polling after a short delay
    Process.send_after(self(), :poll, 1_000)
    {:ok, %{prs: [], last_updated: nil, error: initial_error}}
  end

  @impl true
  def handle_call(:get_prs, _from, state) do
    {:reply, %{
      prs: state.prs,
      last_updated: state.last_updated,
      error: state.error
    }, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    # Fetch async to avoid blocking GenServer calls
    parent = self()
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      new_state = fetch_all_prs(state)
      send(parent, {:poll_complete, new_state})
    end)
    {:noreply, state}
  end

  def handle_info({:poll_complete, new_state}, _state) do
    # Broadcast update to subscribers
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @topic,
      {:pr_update, %{
        prs: new_state.prs,
        last_updated: new_state.last_updated,
        error: new_state.error
      }}
    )
    
    # Schedule next poll
    Process.send_after(self(), :poll, @poll_interval_ms)
    
    {:noreply, new_state}
  end

  # Private functions

  defp fetch_all_prs(state) do
    results =
      @repos
      |> Enum.flat_map(fn repo ->
        case fetch_prs_for_repo(repo) do
          {:ok, prs} -> prs
          {:error, _reason} -> []
        end
      end)
      |> sort_prs()

    %{state |
      prs: results,
      last_updated: DateTime.utc_now(),
      error: nil
    }
  rescue
    e ->
      Logger.error("Failed to fetch PRs: #{inspect(e)}")
      %{state | error: "Failed to fetch PRs"}
  end

  defp fetch_prs_for_repo(repo) do
    args = [
      "pr", "list",
      "--repo", repo,
      "--json", "number,title,state,headRefName,url,statusCheckRollup,reviews,createdAt,author,mergeable",
      "--state", "open"
    ]
    
    case CLITools.run_json_if_available("gh", args, timeout: @cli_timeout_ms, friendly_name: "GitHub CLI") do
      {:ok, prs} when is_list(prs) ->
        {:ok, Enum.map(prs, &parse_pr(&1, repo))}
        
      {:ok, _} ->
        {:error, :unexpected_format}
      
      {:error, {:tool_not_available, message}} ->
        Logger.info("GitHub CLI not available for repo #{repo}: #{message}")
        {:error, message}
        
      {:error, :timeout} ->
        Logger.warning("GitHub CLI timeout for repo #{repo}")
        {:error, :timeout}
        
      {:error, {:exit, _code, error}} ->
        Logger.warning("GitHub CLI error for repo #{repo}: #{error}")
        {:error, error}
        
      {:error, reason} ->
        Logger.warning("GitHub CLI error for repo #{repo}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_pr(pr_data, repo) do
    title = Map.get(pr_data, "title", "")
    branch = Map.get(pr_data, "headRefName", "")
    
    # Parse Linear ticket IDs from title and branch
    ticket_ids = extract_ticket_ids("#{title} #{branch}")
    
    # Parse CI status from statusCheckRollup
    ci_status = parse_ci_status(Map.get(pr_data, "statusCheckRollup"))
    
    # Parse review status from reviews
    review_status = parse_review_status(Map.get(pr_data, "reviews", []))
    
    # Check for merge conflicts
    has_conflicts = Map.get(pr_data, "mergeable") == "CONFLICTING"
    
    %{
      number: Map.get(pr_data, "number"),
      title: title,
      state: Map.get(pr_data, "state"),
      branch: branch,
      url: Map.get(pr_data, "url"),
      repo: repo,
      author: get_in(pr_data, ["author", "login"]) || "unknown",
      created_at: parse_datetime(Map.get(pr_data, "createdAt")),
      ci_status: ci_status,
      review_status: review_status,
      ticket_ids: ticket_ids,
      has_conflicts: has_conflicts
    }
  end

  # Extract ticket IDs like COR-123, FRE-456 from text
  defp extract_ticket_ids(text) do
    ~r/(COR|FRE)-\d+/i
    |> Regex.scan(text)
    |> Enum.map(fn [full_match | _] -> String.upcase(full_match) end)
    |> Enum.uniq()
  end

  # Parse CI status from statusCheckRollup
  defp parse_ci_status(nil), do: :unknown
  defp parse_ci_status([]), do: :unknown
  defp parse_ci_status(checks) when is_list(checks) do
    statuses = Enum.map(checks, fn check ->
      case Map.get(check, "conclusion") do
        "SUCCESS" -> :success
        "FAILURE" -> :failure
        "NEUTRAL" -> :neutral
        nil -> :pending  # In progress
        _ -> :unknown
      end
    end)
    
    cond do
      Enum.any?(statuses, &(&1 == :failure)) -> :failure
      Enum.any?(statuses, &(&1 == :pending)) -> :pending
      Enum.all?(statuses, &(&1 == :success)) -> :success
      true -> :unknown
    end
  end
  defp parse_ci_status(_), do: :unknown

  # Parse review status from reviews array
  defp parse_review_status(nil), do: :pending
  defp parse_review_status([]), do: :pending
  defp parse_review_status(reviews) when is_list(reviews) do
    # Get latest review state per author
    latest_by_author = 
      reviews
      |> Enum.group_by(&get_in(&1, ["author", "login"]))
      |> Enum.map(fn {_author, author_reviews} ->
        # Take the last one (most recent)
        List.last(author_reviews)
      end)
      |> Enum.map(&Map.get(&1, "state"))
    
    cond do
      Enum.any?(latest_by_author, &(&1 == "CHANGES_REQUESTED")) -> :changes_requested
      Enum.any?(latest_by_author, &(&1 == "APPROVED")) -> :approved
      Enum.any?(latest_by_author, &(&1 == "COMMENTED")) -> :commented
      true -> :pending
    end
  end
  defp parse_review_status(_), do: :pending

  # Parse ISO8601 datetime string
  defp parse_datetime(nil), do: nil
  defp parse_datetime(datetime_str) when is_binary(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
  defp parse_datetime(_), do: nil

  # Build Linear ticket URL
  def build_ticket_url(ticket_id) do
    "https://linear.app/#{@linear_workspace}/issue/#{ticket_id}"
  end

  defp sort_prs(prs) do
    # Sort by created_at descending (newest first)
    Enum.sort_by(prs, fn pr ->
      case pr.created_at do
        %DateTime{} = dt -> {0, DateTime.to_unix(dt)}
        _ -> {1, 0}
      end
    end, :desc)
  end
end
