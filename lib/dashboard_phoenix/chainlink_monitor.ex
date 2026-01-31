defmodule DashboardPhoenix.ChainlinkMonitor do
  @moduledoc """
  Monitors Chainlink issues by polling the chainlink CLI.
  Fetches open issues and tracks them for work assignment.
  """

  use GenServer
  require Logger

  alias DashboardPhoenix.CommandRunner
  alias DashboardPhoenix.Paths

  @poll_interval_ms 60_000  # 60 seconds (chainlink issues change less frequently)
  @topic "chainlink_updates"
  @cli_timeout_ms 30_000

  # Get the repository path from configuration
  defp repo_path, do: Paths.systematic_repo()

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all cached issues"
  def get_issues do
    GenServer.call(__MODULE__, :get_issues)
  end

  @doc "Force refresh issues from Chainlink"
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Subscribe to issue updates"
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @topic)
  end

  @doc "Get full details for a specific issue"
  def get_issue_details(issue_id) do
    case CommandRunner.run("chainlink", ["show", to_string(issue_id)],
           cd: repo_path(),
           timeout: @cli_timeout_ms) do
      {:ok, output} ->
        {:ok, output}

      {:error, {:exit, _code, error}} ->
        Logger.warning("Chainlink CLI error fetching ##{issue_id}: #{error}")
        {:error, error}

      {:error, :timeout} ->
        Logger.warning("Chainlink CLI timeout fetching ##{issue_id}")
        {:error, "Command timed out"}

      {:error, reason} ->
        Logger.warning("Chainlink CLI error fetching ##{issue_id}: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Start polling after a short delay
    Process.send_after(self(), :poll, 1_000)
    {:ok, %{issues: [], last_updated: nil, error: nil}}
  end

  @impl true
  def handle_call(:get_issues, _from, state) do
    {:reply, %{
      issues: state.issues,
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
      new_state = fetch_issues(state)
      send(parent, {:poll_complete, new_state})
    end)
    {:noreply, state}
  end

  def handle_info({:poll_complete, new_state}, _state) do
    # Broadcast update to subscribers
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @topic,
      {:chainlink_update, %{
        issues: new_state.issues,
        last_updated: new_state.last_updated,
        error: new_state.error
      }}
    )

    # Schedule next poll
    Process.send_after(self(), :poll, @poll_interval_ms)

    {:noreply, new_state}
  end

  # Private functions

  defp fetch_issues(state) do
    case CommandRunner.run("chainlink", ["list"],
           cd: repo_path(),
           timeout: @cli_timeout_ms) do
      {:ok, output} ->
        issues = parse_chainlink_output(output)
        %{state |
          issues: issues,
          last_updated: DateTime.utc_now(),
          error: nil
        }

      {:error, {:exit, code, error}} ->
        Logger.warning("Chainlink CLI error (exit #{code}): #{error}")
        %{state | error: "Failed to fetch issues: #{String.slice(error, 0, 100)}"}

      {:error, :timeout} ->
        Logger.warning("Chainlink CLI timeout")
        %{state | error: "Command timed out"}

      {:error, reason} ->
        Logger.warning("Chainlink CLI error: #{inspect(reason)}")
        %{state | error: "Failed to fetch issues"}
    end
  rescue
    e ->
      Logger.error("Failed to fetch Chainlink issues: #{inspect(e)}")
      %{state | error: "Failed to fetch issues"}
  end

  defp parse_chainlink_output(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_issue_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_issue_line(line) do
    # Remove ANSI codes
    clean_line = String.replace(line, ~r/\e\[[0-9;]*m/, "")

    # Parse format: "#17   [open]   Add Chainlink issues panel with Work ... high     2026-01-31"
    # Format: #ID   [status]   Title   Priority   Due
    case Regex.run(
           ~r/^#(\d+)\s+\[(\w+)\]\s+(.+?)\s{2,}(\w+)\s+(\d{4}-\d{2}-\d{2})?/,
           clean_line
         ) do
      [_, id, status, title, priority, due] ->
        %{
          id: String.to_integer(id),
          status: status,
          title: String.trim(title),
          priority: normalize_priority(priority),
          due: due
        }

      _ ->
        # Try simpler format without due date
        case Regex.run(~r/^#(\d+)\s+\[(\w+)\]\s+(.+?)\s{2,}(\w+)/, clean_line) do
          [_, id, status, title, priority] ->
            %{
              id: String.to_integer(id),
              status: status,
              title: String.trim(title),
              priority: normalize_priority(priority),
              due: nil
            }

          _ ->
            nil
        end
    end
  end

  defp normalize_priority(priority) do
    case String.downcase(priority) do
      "high" -> :high
      "medium" -> :medium
      "low" -> :low
      _ -> :medium
    end
  end
end
