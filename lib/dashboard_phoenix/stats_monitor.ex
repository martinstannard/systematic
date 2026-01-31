defmodule DashboardPhoenix.StatsMonitor do
  @moduledoc """
  Fetches usage stats from OpenCode and Claude Code.
  """
  use GenServer

  alias DashboardPhoenix.Paths

  @poll_interval 5_000  # 5 seconds

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
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
    stats = fetch_all_stats()
    {:ok, %{stats: stats}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    stats = fetch_all_stats()
    broadcast_stats(stats)
    {:noreply, %{state | stats: stats}}
  end

  @impl true
  def handle_info(:poll, state) do
    stats = fetch_all_stats()
    if stats != state.stats do
      broadcast_stats(stats)
    end
    schedule_poll()
    {:noreply, %{state | stats: stats}}
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
    case System.cmd("opencode", ["stats"], stderr_to_stdout: true) do
      {output, 0} -> parse_opencode_stats(output)
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
      _ -> %{error: "No stats file"}
    end
  end

  defp parse_claude_stats(data) do
    models = data["modelUsage"] || %{}
    
    total_input = models |> Map.values() |> Enum.map(&(&1["inputTokens"] || 0)) |> Enum.sum()
    total_output = models |> Map.values() |> Enum.map(&(&1["outputTokens"] || 0)) |> Enum.sum()
    total_cache_read = models |> Map.values() |> Enum.map(&(&1["cacheReadInputTokens"] || 0)) |> Enum.sum()
    
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
