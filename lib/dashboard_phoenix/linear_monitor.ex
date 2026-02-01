defmodule DashboardPhoenix.LinearMonitor do
  @moduledoc """
  Monitors Linear tickets for the COR team by polling the Linear CLI.
  Fetches tickets in Triage, Backlog, and Todo states.
  """

  use GenServer
  require Logger

  alias DashboardPhoenix.{Paths, CLITools, StatePersistence}

  @poll_interval_ms 30_000  # 30 seconds
  @topic "linear_updates"
  @linear_workspace "fresh-clinics"  # Workspace slug for URLs
  @states ["Triaging", "Backlog", "Todo", "In Review"]
  @cli_timeout_ms 30_000
  @persistence_file "linear_state.json"

  defp linear_cli, do: Paths.linear_cli()

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all cached tickets"
  def get_tickets do
    GenServer.call(__MODULE__, :get_tickets)
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
    case CLITools.run_if_available(linear_cli(), ["issue", "show", ticket_id], 
         timeout: @cli_timeout_ms, friendly_name: "Linear CLI") do
      {:ok, output} ->
        {:ok, output}
      
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

  # Server callbacks

  @impl true
  def init(_opts) do
    # Check tool availability on startup
    tools_status = CLITools.check_tools([
      {linear_cli(), "Linear CLI"},
      {"gh", "GitHub CLI"}
    ])
    
    initial_error = if tools_status.all_available? do
      nil
    else
      CLITools.format_status_message(tools_status)
    end
    
    if initial_error do
      Logger.warning("LinearMonitor starting with missing tools: #{initial_error}")
    end
    
    # Load persisted state
    default_ticket = %{id: "", title: "", status: "", project: nil, assignee: nil, priority: nil, url: "", pr_url: nil}
    default_state = %{tickets: [default_ticket], last_updated: nil, error: initial_error}
    persisted_state = StatePersistence.load(@persistence_file, default_state)
    
    # If we only have our default ticket and it was not in the file, clear it
    # This happens if the file was missing or empty tickets list was saved
    persisted_state = if persisted_state.tickets == [default_ticket], 
                        do: %{persisted_state | tickets: []}, 
                        else: persisted_state

    # Ensure last_updated is a DateTime if it was loaded as a string
    state = fix_loaded_state(persisted_state, initial_error)
    
    # Start polling after a short delay
    Process.send_after(self(), :poll, 1_000)
    {:ok, state}
  end

  defp fix_loaded_state(state, current_error) do
    state = case state.last_updated do
      nil -> state
      %DateTime{} -> state
      iso_str when is_binary(iso_str) ->
        case DateTime.from_iso8601(iso_str) do
          {:ok, dt, _} -> %{state | last_updated: dt}
          _ -> %{state | last_updated: nil}
        end
      _ -> %{state | last_updated: nil}
    end
    
    # Always use the current tools error
    %{state | error: current_error}
  end

  @impl true
  def handle_call(:get_tickets, _from, state) do
    {:reply, %{
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
    # Fetch async to avoid blocking GenServer calls
    parent = self()
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      new_state = fetch_all_tickets(state)
      send(parent, {:poll_complete, new_state})
    end)
    {:noreply, state}
  end

  def handle_info({:poll_complete, new_state}, _state) do
    # Persist successful poll (if no error)
    if is_nil(new_state.error) do
      StatePersistence.save(@persistence_file, new_state)
    end

    # Broadcast update to subscribers
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @topic,
      {:linear_update, %{
        tickets: new_state.tickets,
        last_updated: new_state.last_updated,
        error: new_state.error
      }}
    )
    
    # Schedule next poll
    Process.send_after(self(), :poll, @poll_interval_ms)
    
    {:noreply, new_state}
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

    %{state |
      tickets: results,
      last_updated: DateTime.utc_now(),
      error: nil
    }
  rescue
    e ->
      Logger.error("Failed to fetch Linear tickets: #{inspect(e)}")
      %{state | error: "Failed to fetch tickets"}
  end

  defp fetch_tickets_for_state(status) do
    case CLITools.run_if_available(linear_cli(), ["issues", "--state", status], 
         timeout: @cli_timeout_ms, friendly_name: "Linear CLI") do
      {:ok, output} ->
        {:ok, parse_issues_output(output, status)}
      
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

  defp parse_issues_output(output, status) do
    output
    |> String.split("\n")
    |> Enum.drop(2)  # Skip header lines (title + empty line)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_issue_line(&1, status))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_issue_line(line, status) do
    # Remove ANSI codes
    clean_line = String.replace(line, ~r/\e\[[0-9;]*m/, "")
    
    # Parse format: "COR-XXX  Title...  State  Project  Assignee"
    # The fields are separated by 2+ spaces
    case Regex.run(~r/^(COR-\d+)\s{2,}(.+?)\s{2,}(\w+)\s{2,}(.+?)\s{2,}(.*)$/, clean_line) do
      [_, id, title, _state, project, assignee] ->
        ticket = %{
          id: String.trim(id),
          title: String.trim(title),
          status: status,
          project: normalize_project(project),
          assignee: normalize_assignee(assignee),
          priority: nil,  # Not in the list output
          url: build_issue_url(id)
        }
        add_pr_info(ticket)
      
      _ ->
        # Try simpler format (fewer columns)
        case Regex.run(~r/^(COR-\d+)\s{2,}(.+?)\s{2,}(\w+)/, clean_line) do
          [_, id, title, _state | rest] ->
            ticket = %{
              id: String.trim(id),
              title: String.trim(title),
              status: status,
              project: nil,
              assignee: parse_assignee_from_rest(rest),
              priority: nil,
              url: build_issue_url(id)
            }
            add_pr_info(ticket)
          
          _ ->
            # Last resort: just grab the ID and rest as title
            case Regex.run(~r/^(COR-\d+)\s+(.+)/, clean_line) do
              [_, id, rest] ->
                ticket = %{
                  id: String.trim(id),
                  title: String.trim(rest),
                  status: status,
                  project: nil,
                  assignee: nil,
                  priority: nil,
                  url: build_issue_url(id)
                }
                add_pr_info(ticket)
              
              _ ->
                nil
            end
        end
    end
  end

  defp normalize_project("-"), do: nil
  defp normalize_project(project), do: String.trim(project)

  defp normalize_assignee("-"), do: nil
  defp normalize_assignee("you"), do: "you"
  defp normalize_assignee(assignee), do: String.trim(assignee)

  defp parse_assignee_from_rest([]), do: nil
  defp parse_assignee_from_rest([rest | _]) do
    trimmed = String.trim(rest)
    if trimmed == "-" or trimmed == "", do: nil, else: trimmed
  end

  defp build_issue_url(issue_id) do
    "https://linear.app/#{@linear_workspace}/issue/#{issue_id}"
  end

  defp add_pr_info(%{status: "In Review", id: ticket_id} = ticket) do
    case lookup_pr(ticket_id) do
      {:ok, pr_url} -> Map.put(ticket, :pr_url, pr_url)
      {:error, _} -> Map.put(ticket, :pr_url, nil)
    end
  end
  defp add_pr_info(ticket), do: Map.put(ticket, :pr_url, nil)

  defp lookup_pr(ticket_id) do
    case CLITools.run_json_if_available("gh", [
      "pr", "list",
      "--repo", "Fresh-Clinics/core-platform",
      "--search", ticket_id,
      "--state", "open",
      "--json", "number,url",
      "--limit", "1"
    ], timeout: @cli_timeout_ms, friendly_name: "GitHub CLI") do
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
        [_, num] -> -String.to_integer(num)  # Negative for descending
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
