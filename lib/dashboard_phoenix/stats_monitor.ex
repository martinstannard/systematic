defmodule DashboardPhoenix.StatsMonitor do
  @moduledoc """
  Fetches usage stats from OpenCode and Claude Code.
  """
  use GenServer
  require Logger

  alias DashboardPhoenix.{CLITools, Paths, StatePersistence}

  # 5 seconds
  @poll_interval 5_000
  @persistence_file "stats_state.json"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats, 5_000)
  end

  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "stats")
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    schedule_poll()

    # Load persisted state
    default_stats = %{
      opencode: %{
        sessions: 0,
        messages: 0,
        days: 0,
        total_cost: "$0",
        input_tokens: "0",
        output_tokens: "0",
        cache_read: "0"
      },
      claude: %{
        sessions: 0,
        messages: 0,
        input_tokens: "0",
        output_tokens: "0",
        cache_read: "0",
        models: []
      },
      updated_at: 0
    }

    persisted_state = StatePersistence.load(@persistence_file, %{stats: default_stats})

    # Try to fetch fresh stats, but fallback to persisted if fails
    stats =
      case fetch_all_stats() do
        %{opencode: %{error: _}, claude: %{error: _}} ->
          # Both failed, use persisted
          persisted_state.stats

        fresh_stats ->
          fresh_stats
      end

    {:ok, %{stats: stats}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    stats = fetch_all_stats()

    # Fallback to current state if all fetchers returned error
    final_stats =
      if is_all_error?(stats) do
        Logger.warning("Stats fetch failed during refresh, using cached state")
        state.stats
      else
        StatePersistence.save(@persistence_file, %{stats: stats})
        stats
      end

    broadcast_stats(final_stats)
    {:noreply, %{state | stats: final_stats}}
  end

  @impl true
  def handle_info(:poll, state) do
    stats = fetch_all_stats()

    final_stats =
      if is_all_error?(stats) do
        # Don't log on every poll to avoid spam
        state.stats
      else
        if stats != state.stats do
          StatePersistence.save(@persistence_file, %{stats: stats})
          broadcast_stats(stats)
        end

        stats
      end

    schedule_poll()
    {:noreply, %{state | stats: final_stats}}
  end

  defp is_all_error?(stats) do
    match?(%{opencode: %{error: _}, claude: %{error: _}}, stats)
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp fetch_all_stats do
    %{
      opencode: fetch_opencode_stats(),
      claude: fetch_claude_stats(),
      updated_at: System.system_time(:second)
    }
  end

  defp fetch_opencode_stats do
    # Use CLITools with a short timeout for stats (should be quick)
    case CLITools.run_if_available("opencode", ["stats"],
           timeout: 10_000,
           stderr_to_stdout: true,
           friendly_name: "OpenCode"
         ) do
      {:ok, output} -> parse_opencode_stats(output)
      {:error, {:tool_not_available, message}} -> %{error: message}
      {:error, :timeout} -> %{error: "Timeout fetching stats"}
      {:error, {:exit, _code, output}} -> %{error: "Command failed: #{String.trim(output)}"}
      _ -> %{error: "Failed to fetch"}
    end
  end

  defp parse_opencode_stats(output) do
    # Parse the key stats from opencode output
    %{
      sessions: extract_stat(output, ~r/Sessions\s+(\d+)/),
      messages: extract_stat(output, ~r/Messages\s+(\d+)/),
      days: extract_stat(output, ~r/Days\s+(\d+)/),
      total_cost: extract_string(output, ~r/Total Cost\s+(\$[\d.]+)/),
      input_tokens: extract_string(output, ~r/Input\s+([\d.]+[KMG]?)/),
      output_tokens: extract_string(output, ~r/Output\s+([\d.]+[KMG]?)/),
      cache_read: extract_string(output, ~r/Cache Read\s+([\d.]+[KMG]?)/)
    }
  end

  defp fetch_claude_stats do
    stats_file = Paths.claude_stats_file()

    case File.read(stats_file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> parse_claude_stats(data)
          _ -> %{error: "Invalid JSON"}
        end

      _ ->
        %{error: "No stats file"}
    end
  end

  defp parse_claude_stats(data) do
    models = data["modelUsage"] || %{}

    total_input = models |> Map.values() |> Enum.map(&(&1["inputTokens"] || 0)) |> Enum.sum()
    total_output = models |> Map.values() |> Enum.map(&(&1["outputTokens"] || 0)) |> Enum.sum()

    total_cache_read =
      models |> Map.values() |> Enum.map(&(&1["cacheReadInputTokens"] || 0)) |> Enum.sum()

    %{
      sessions: data["totalSessions"] || 0,
      messages: data["totalMessages"] || 0,
      input_tokens: format_tokens(total_input),
      output_tokens: format_tokens(total_output),
      cache_read: format_tokens(total_cache_read),
      models: Map.keys(models)
    }
  end

  defp extract_stat(text, regex) do
    case Regex.run(regex, text) do
      [_, value] -> String.to_integer(value)
      _ -> 0
    end
  end

  defp extract_string(text, regex) do
    case Regex.run(regex, text) do
      [_, value] -> value
      _ -> "N/A"
    end
  end

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"

  defp broadcast_stats(stats) do
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "stats", {:stats_updated, stats})
  end
end
