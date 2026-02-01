defmodule DashboardPhoenix.ChainlinkMonitor do
  @moduledoc """
  Monitors Chainlink issues by polling the chainlink CLI.
  Fetches open issues and tracks them for work assignment.
  
  ## Performance Optimizations (Ticket #71)
  
  - Uses ETS for fast data reads (no GenServer.call blocking)
  - GenServer only manages lifecycle and periodic polling
  - All public getters read directly from ETS
  """

  use GenServer
  require Logger

  alias DashboardPhoenix.{CLITools, Paths}

  @poll_interval_ms 60_000  # 60 seconds (chainlink issues change less frequently)
  @topic "chainlink_updates"
  @cli_timeout_ms 30_000
  
  # ETS table name for fast reads
  @ets_table :chainlink_monitor_data

  # Get the repository path from configuration
  defp repo_path, do: Paths.systematic_repo()

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all cached issues. Reads directly from ETS (non-blocking)."
  def get_issues do
    case :ets.lookup(@ets_table, :issues) do
      [{:issues, data}] -> data
      [] -> %{issues: [], last_updated: nil, error: nil}
    end
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
    case CLITools.run_if_available(Paths.chainlink_bin(), ["show", to_string(issue_id)],
           cd: repo_path(),
           timeout: @cli_timeout_ms,
           friendly_name: "Chainlink CLI") do
      {:ok, output} ->
        {:ok, output}

      {:error, {:tool_not_available, message}} ->
        Logger.info("Chainlink CLI not available for issue ##{issue_id}: #{message}")
        {:error, message}

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
    # Create ETS table for fast reads (Ticket #71)
    :ets.new(@ets_table, [:named_table, :public, :set, read_concurrency: true])
    
    # Initialize ETS with empty data
    :ets.insert(@ets_table, {:issues, %{issues: [], last_updated: nil, error: nil}})
    
    # Check tool availability on startup
    tools_status = CLITools.check_tools([
      {Paths.chainlink_bin(), "Chainlink CLI"}
    ])
    
    initial_error = if tools_status.all_available? do
      nil
    else
      CLITools.format_status_message(tools_status)
    end
    
    if initial_error do
      Logger.warning("ChainlinkMonitor starting with missing tools: #{initial_error}")
    end
    
    # Start polling after a short delay
    Process.send_after(self(), :poll, 1_000)
    {:ok, %{issues: [], last_updated: nil, error: initial_error}}
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
    # Update ETS (Ticket #71)
    :ets.insert(@ets_table, {:issues, %{
      issues: new_state.issues,
      last_updated: new_state.last_updated,
      error: new_state.error
    }})
    
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

  # Private functions (some exposed for testing)

  @doc false
  def parse_chainlink_output_for_test(output), do: parse_chainlink_output(output)

  @doc false  
  def parse_issue_line_for_test(line), do: parse_issue_line(line)

  @doc false
  def normalize_priority_for_test(priority), do: normalize_priority(priority)

  defp fetch_issues(state) do
    case CLITools.run_if_available(Paths.chainlink_bin(), ["list"],
           cd: repo_path(),
           timeout: @cli_timeout_ms,
           friendly_name: "Chainlink CLI") do
      {:ok, output} ->
        issues = parse_chainlink_output(output)
        %{state |
          issues: issues,
          last_updated: DateTime.utc_now(),
          error: nil
        }

      {:error, {:tool_not_available, message}} ->
        Logger.info("Chainlink CLI not available: #{message}")
        %{state | error: message}

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
    # Try with due date first (more specific pattern)
    case Regex.run(~r/^#(\d+)\s+\[(\w+)\]\s+(.+?)\s+(\w+)\s+(\d{4}-\d{2}-\d{2})$/, clean_line) do
      [_, id, status, title, priority, due] ->
        %{
          id: String.to_integer(id),
          status: status,
          title: String.trim(title),
          priority: normalize_priority(priority),
          due: due
        }

      _ ->
        # Try without due date
        case Regex.run(~r/^#(\d+)\s+\[(\w+)\]\s+(.+?)\s+(\w+)$/, clean_line) do
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
