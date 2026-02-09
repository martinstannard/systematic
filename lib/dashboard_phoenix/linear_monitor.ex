defmodule DashboardPhoenix.LinearMonitor do
  @moduledoc """
  Monitors Linear tickets for the COR team by polling the Linear CLI.
  Fetches tickets in Triage, Backlog, and Todo states.

  ## Performance Optimizations (Ticket #73)

  - Increased poll interval from 30s to 60s
  - Exponential backoff on failures (up to 5 minutes)
  - CLI result caching to avoid redundant calls
  """

  use GenServer
  require Logger

  alias DashboardPhoenix.{Paths, CLITools, StatePersistence, CLICache, Status}

  # 60 seconds (Ticket #73: increased from 30s)
  @poll_interval_ms 60_000
  # 5 minutes max backoff
  @max_poll_interval_ms 300_000
  @topic "linear_updates"
  # Workspace slug for URLs
  @linear_workspace "fresh-clinics"
  @states Status.linear_states()
  @cli_timeout_ms 30_000
  # Cache CLI results for 45 seconds
  @cache_ttl_ms 45_000
  @persistence_file "linear_state.json"

  defp linear_cli, do: Paths.linear_cli()

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc "Get all cached tickets"
  def get_tickets do
    GenServer.call(__MODULE__, :get_tickets, 5_000)
  end

  @doc "Force refresh tickets from Linear"
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Subscribe to ticket updates"
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @topic)
  end

  @doc "Get full details for a specific ticket"
  def get_ticket_details(ticket_id) do
    # Ticket #115: Use JSON output for more reliable parsing
    case CLITools.run_json_if_available(linear_cli(), ["issue", "show", ticket_id, "--json"],
           timeout: @cli_timeout_ms,
           friendly_name: "Linear CLI"
         ) do
      {:ok, data} when is_map(data) ->
        {:ok, format_ticket_details(data)}

      {:error, {:tool_not_available, message}} ->
        Logger.info("Linear CLI not available for ticket #{ticket_id}: #{message}")
        {:error, message}

      {:error, {:exit, _code, error}} ->
        Logger.warning("Linear CLI error fetching #{ticket_id}: #{error}")
        {:error, String.trim(error)}

      {:error, :timeout} ->
        Logger.warning("Linear CLI timeout fetching #{ticket_id}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.warning("Linear CLI error fetching #{ticket_id}: #{inspect(reason)}")
        {:error, format_error(reason)}
    end
  end

  # Format ticket details into a readable string from JSON data
  defp format_ticket_details(data) do
    lines = [
      "# #{data["id"]}: #{data["title"]}",
      "",
      "State: #{data["status"]}",
      "Priority: #{data["priority"] || "None"}",
      "Project: #{data["project"] || "None"}",
      "Assignee: #{data["assignee"] || "Unassigned"}",
      "Labels: #{format_labels(data["labels"])}"
    ]

    lines =
      if data["parent"] do
        lines ++ ["", "## Parent", "#{data["parent"]["id"]}: #{data["parent"]["title"]}"]
      else
        lines
      end

    lines =
      if data["children"] && length(data["children"]) > 0 do
        children_lines =
          Enum.map(data["children"], fn c ->
            "  - [#{c["status"]}] #{c["id"]}: #{c["title"]}"
          end)

        lines ++ ["", "## Sub-issues"] ++ children_lines
      else
        lines
      end

    lines =
      if data["blockedBy"] && length(data["blockedBy"]) > 0 do
        blocked_lines =
          Enum.map(data["blockedBy"], fn b ->
            "  - #{b["id"]}: #{b["title"]}"
          end)

        lines ++ ["", "## Blocked by"] ++ blocked_lines
      else
        lines
      end

    lines =
      if data["blocks"] && length(data["blocks"]) > 0 do
        blocks_lines =
          Enum.map(data["blocks"], fn b ->
            "  - #{b["id"]}: #{b["title"]}"
          end)

        lines ++ ["", "## Blocks"] ++ blocks_lines
      else
        lines
      end

    lines = lines ++ ["", "## Description", "", data["description"] || "No description"]

    lines =
      if data["comments"] && length(data["comments"]) > 0 do
        comment_lines =
          Enum.flat_map(data["comments"], fn c ->
            ["", "---", "**#{c["author"]}** (#{c["createdAt"]})", "", c["body"]]
          end)

        lines ++ ["", "## Comments"] ++ comment_lines
      else
        lines
      end

    Enum.join(lines, "\n")
  end

  defp format_labels(nil), do: "None"
  defp format_labels([]), do: "None"
  defp format_labels(labels), do: Enum.join(labels, ", ")

  # Server callbacks

  @impl true
  def init(_opts) do
    # Check tool availability on startup
    tools_status =
      CLITools.check_tools([
        {linear_cli(), "Linear CLI"},
        {"gh", "GitHub CLI"}
      ])

    initial_error =
      if tools_status.all_available? do
        nil
      else
        CLITools.format_status_message(tools_status)
      end

    if initial_error do
      Logger.warning("LinearMonitor starting with missing tools: #{initial_error}")
    end

    # Load persisted state
    default_ticket = %{
      id: "",
      title: "",
      status: "",
      project: nil,
      assignee: nil,
      priority: nil,
      url: "",
      pr_url: nil
    }

    default_state = %{tickets: [default_ticket], last_updated: nil, error: initial_error}
    persisted_state = StatePersistence.load(@persistence_file, default_state)

    # If we only have our default ticket and it was not in the file, clear it
    # This happens if the file was missing or empty tickets list was saved
    persisted_state =
      if persisted_state.tickets == [default_ticket],
        do: %{persisted_state | tickets: []},
        else: persisted_state

    # Ensure last_updated is a DateTime if it was loaded as a string
    state = fix_loaded_state(persisted_state, initial_error)

    # Add backoff tracking (Ticket #73) and polling mutex (Ticket #81)
    state =
      Map.merge(state, %{
        consecutive_failures: 0,
        current_interval: @poll_interval_ms,
        # Mutex to prevent concurrent polls
        polling: false
      })

    # Start polling after a short delay
    Process.send_after(self(), :poll, 1_000)
    {:ok, state}
  end

  defp fix_loaded_state(state, current_error) do
    state =
      case state.last_updated do
        nil ->
          state

        %DateTime{} ->
          state

        iso_str when is_binary(iso_str) ->
          case DateTime.from_iso8601(iso_str) do
            {:ok, dt, _} -> %{state | last_updated: dt}
            _ -> %{state | last_updated: nil}
          end

        _ ->
          %{state | last_updated: nil}
      end

    # Ensure required fields exist for race condition fixes (Ticket #81)
    state = Map.put_new(state, :polling, false)

    # Always use the current tools error
    %{state | error: current_error}
  end

  @impl true
  def handle_call(:get_tickets, _from, state) do
    {:reply,
     %{
       tickets: state.tickets,
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
    # Prevent concurrent polls - critical for race condition fix (Ticket #81)
    if state.polling do
      Logger.debug("LinearMonitor: Poll already in progress, skipping")
      Process.send_after(self(), :poll, state.current_interval)
      {:noreply, state}
    else
      # Mark as polling and start async poll
      state = %{state | polling: true}
      parent = self()

      Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
        try do
          new_state = fetch_all_tickets(state)
          send(parent, {:poll_complete, new_state})
        rescue
          e ->
            Logger.error("LinearMonitor: Poll failed: #{inspect(e)}")
            send(parent, {:poll_error, e})
        end
      end)

      {:noreply, state}
    end
  end

  def handle_info({:poll_complete, new_state}, state) do
    # Reset polling flag atomically (Ticket #81)
    new_state = %{new_state | polling: false}

    # Persist successful poll (if no error) - async to avoid blocking
    if is_nil(new_state.error) do
      Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
        StatePersistence.save(@persistence_file, new_state)
      end)
    end

    # Broadcast update to subscribers
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @topic,
      {:linear_update,
       %{
         tickets: new_state.tickets,
         last_updated: new_state.last_updated,
         error: new_state.error
       }}
    )

    # Calculate next poll interval with exponential backoff (Ticket #73)
    {next_interval, consecutive_failures} =
      if is_nil(new_state.error) do
        # Success - reset to base interval
        {@poll_interval_ms, 0}
      else
        # Failure - exponential backoff (double interval, cap at max)
        failures = Map.get(state, :consecutive_failures, 0) + 1

        backoff =
          min(@poll_interval_ms * :math.pow(2, failures), @max_poll_interval_ms) |> trunc()

        Logger.info("LinearMonitor: Failure ##{failures}, backing off to #{div(backoff, 1000)}s")
        {backoff, failures}
      end

    # Schedule next poll
    Process.send_after(self(), :poll, next_interval)

    {:noreply,
     Map.merge(new_state, %{
       consecutive_failures: consecutive_failures,
       current_interval: next_interval
     })}
  end

  @impl true
  def handle_info({:poll_error, _error}, state) do
    # Reset polling flag on error (Ticket #81)
    state = %{state | polling: false, error: "Poll failed"}

    # Calculate backoff interval
    failures = Map.get(state, :consecutive_failures, 0) + 1
    backoff = min(@poll_interval_ms * :math.pow(2, failures), @max_poll_interval_ms) |> trunc()
    Logger.info("LinearMonitor: Failure ##{failures}, backing off to #{div(backoff, 1000)}s")

    # Schedule next poll with backoff
    Process.send_after(self(), :poll, backoff)

    {:noreply, %{state | consecutive_failures: failures, current_interval: backoff}}
  end

  # Private functions

  defp fetch_all_tickets(state) do
    results =
      @states
      |> Enum.map(fn status ->
        case fetch_tickets_for_state(status) do
          {:ok, tickets} -> tickets
          {:error, _reason} -> []
        end
      end)
      |> List.flatten()
      |> sort_tickets()

    %{state | tickets: results, last_updated: DateTime.utc_now(), error: nil}
  rescue
    e ->
      Logger.error("Failed to fetch Linear tickets: #{inspect(e)}")
      %{state | error: "Failed to fetch tickets"}
  end

  defp fetch_tickets_for_state(status) do
    cache_key = "linear:issues:#{status}"

    # Use CLI cache to avoid redundant calls (Ticket #73)
    # Ticket #115: Use JSON output for more reliable parsing
    case CLICache.get_or_fetch(cache_key, @cache_ttl_ms, fn ->
           case CLITools.run_json_if_available(
                  linear_cli(),
                  ["issues", "--state", status, "--json"],
                  timeout: @cli_timeout_ms,
                  friendly_name: "Linear CLI"
                ) do
             {:ok, data} -> {:ok, data}
             error -> error
           end
         end) do
      {:ok, issues} when is_list(issues) ->
        {:ok, parse_json_issues(issues)}

      {:error, {:tool_not_available, message}} ->
        Logger.info("Linear CLI not available for state #{status}: #{message}")
        {:error, message}

      {:error, {:exit, _code, error}} ->
        Logger.warning("Linear CLI error for state #{status}: #{error}")
        {:error, String.trim(error)}

      {:error, :timeout} ->
        Logger.warning("Linear CLI timeout for state #{status}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.warning("Linear CLI error for state #{status}: #{inspect(reason)}")
        {:error, format_error(reason)}
    end
  end

  # Ticket #115: Parse JSON output from Linear CLI for reliable parsing
  defp parse_json_issues(issues) when is_list(issues) do
    issues
    |> Enum.map(&parse_json_issue/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_json_issue(%{"id" => id, "title" => title, "status" => status} = issue) do
    ticket = %{
      id: id,
      title: title,
      status: status,
      project: issue["project"],
      assignee: issue["assignee"],
      priority: issue["priority"],
      url: build_issue_url(id)
    }

    add_pr_info(ticket)
  end

  defp parse_json_issue(_), do: nil

  defp build_issue_url(issue_id) do
    "https://linear.app/#{@linear_workspace}/issue/#{issue_id}"
  end

  defp add_pr_info(%{status: status, id: ticket_id} = ticket) when status == "In Review" do
    case lookup_pr(ticket_id) do
      {:ok, pr_url} -> Map.put(ticket, :pr_url, pr_url)
      {:error, _} -> Map.put(ticket, :pr_url, nil)
    end
  end

  defp add_pr_info(ticket), do: Map.put(ticket, :pr_url, nil)

  defp lookup_pr(ticket_id) do
    case CLITools.run_json_if_available(
           "gh",
           [
             "pr",
             "list",
             "--repo",
             "Fresh-Clinics/core-platform",
             "--search",
             ticket_id,
             "--state",
             "open",
             "--json",
             "number,url",
             "--limit",
             "1"
           ],
           timeout: @cli_timeout_ms,
           friendly_name: "GitHub CLI"
         ) do
      {:ok, [%{"url" => url} | _]} -> {:ok, url}
      {:ok, []} -> {:error, :no_pr_found}
      {:error, {:tool_not_available, _message}} -> {:error, :gh_not_available}
      {:error, _} -> {:error, :command_failed}
    end
  end

  defp sort_tickets(tickets) do
    # Sort by ID descending (highest/newest first)
    Enum.sort_by(tickets, fn ticket ->
      # Extract numeric part from COR-XXX
      case Regex.run(~r/COR-(\d+)/, ticket.id) do
        # Negative for descending
        [_, num] -> -String.to_integer(num)
        _ -> 0
      end
    end)
  end

  # Format error reasons into human-readable strings
  defp format_error(%{reason: reason}) when is_atom(reason), do: to_string(reason)
  defp format_error(%{original: original}) when is_atom(original), do: to_string(original)
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
