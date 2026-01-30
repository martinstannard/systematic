defmodule DashboardPhoenix.LinearMonitor do
  @moduledoc """
  Monitors Linear tickets for the COR team by polling the Linear CLI.
  Fetches tickets in Triage, Backlog, and Todo states.
  """

  use GenServer
  require Logger

  @poll_interval_ms 30_000  # 30 seconds
  @topic "linear_updates"
  @linear_workspace "fresh-clinics"  # Workspace slug for URLs
  @states ["Triage", "Backlog", "Todo"]

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

  # Server callbacks

  @impl true
  def init(_opts) do
    # Start polling after a short delay
    Process.send_after(self(), :poll, 1_000)
    {:ok, %{tickets: [], last_updated: nil, error: nil}}
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
    new_state = fetch_all_tickets(state)
    
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
    case System.cmd("linear", ["issues", "--state", status], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, parse_issues_output(output, status)}
      
      {error, _code} ->
        Logger.warning("Linear CLI error for state #{status}: #{error}")
        {:error, error}
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
        %{
          id: String.trim(id),
          title: String.trim(title),
          status: status,
          project: normalize_project(project),
          assignee: normalize_assignee(assignee),
          priority: nil,  # Not in the list output
          url: build_issue_url(id)
        }
      
      _ ->
        # Try simpler format (fewer columns)
        case Regex.run(~r/^(COR-\d+)\s{2,}(.+?)\s{2,}(\w+)/, clean_line) do
          [_, id, title, _state | rest] ->
            %{
              id: String.trim(id),
              title: String.trim(title),
              status: status,
              project: nil,
              assignee: parse_assignee_from_rest(rest),
              priority: nil,
              url: build_issue_url(id)
            }
          
          _ ->
            # Last resort: just grab the ID and rest as title
            case Regex.run(~r/^(COR-\d+)\s+(.+)/, clean_line) do
              [_, id, rest] ->
                %{
                  id: String.trim(id),
                  title: String.trim(rest),
                  status: status,
                  project: nil,
                  assignee: nil,
                  priority: nil,
                  url: build_issue_url(id)
                }
              
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

  defp sort_tickets(tickets) do
    # Sort by status priority (Triage > Todo > Backlog), then by ID
    status_order = %{"Triage" => 0, "Todo" => 1, "Backlog" => 2}
    
    Enum.sort_by(tickets, fn ticket ->
      {Map.get(status_order, ticket.status, 99), ticket.id}
    end)
  end
end
