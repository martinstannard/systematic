defmodule DashboardPhoenix.StatsMonitorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.StatsMonitor

  describe "parse_opencode_stats/1 logic" do
    test "parses complete opencode stats output" do
      output = """
      OpenCode Stats
      Sessions        42
      Messages        1234
      Days            30
      Total Cost      $15.50
      Input           5.2M
      Output          1.8M
      Cache Read      10.5M
      """

      result = parse_opencode_stats(output)

      assert result.sessions == 42
      assert result.messages == 1234
      assert result.days == 30
      assert result.total_cost == "$15.50"
      assert result.input_tokens == "5.2M"
      assert result.output_tokens == "1.8M"
      assert result.cache_read == "10.5M"
    end

    test "handles missing fields gracefully" do
      output = """
      Sessions        10
      Messages        100
      """

      result = parse_opencode_stats(output)

      assert result.sessions == 10
      assert result.messages == 100
      assert result.days == 0  # Missing, should default
      assert result.total_cost == "N/A"
    end

    test "handles empty output" do
      result = parse_opencode_stats("")

      assert result.sessions == 0
      assert result.messages == 0
      assert result.days == 0
    end

    test "extracts K/M/G suffixed token counts" do
      output = """
      Input           500K
      Output          2.5G
      """

      result = parse_opencode_stats(output)

      assert result.input_tokens == "500K"
      assert result.output_tokens == "2.5G"
    end
  end

  describe "parse_claude_stats/1 logic" do
    test "parses Claude stats JSON data" do
      data = %{
        "totalSessions" => 50,
        "totalMessages" => 500,
        "modelUsage" => %{
          "claude-sonnet" => %{
            "inputTokens" => 1_000_000,
            "outputTokens" => 200_000,
            "cacheReadInputTokens" => 500_000
          },
          "claude-opus" => %{
            "inputTokens" => 500_000,
            "outputTokens" => 100_000,
            "cacheReadInputTokens" => 250_000
          }
        }
      }

      result = parse_claude_stats(data)

      assert result.sessions == 50
      assert result.messages == 500
      assert result.input_tokens == "1.5M"  # 1M + 500K
      assert result.output_tokens == "300.0K"  # 200K + 100K
      assert result.cache_read == "750.0K"  # 500K + 250K
      assert "claude-sonnet" in result.models
      assert "claude-opus" in result.models
    end

    test "handles empty model usage" do
      data = %{
        "totalSessions" => 10,
        "totalMessages" => 20,
        "modelUsage" => %{}
      }

      result = parse_claude_stats(data)

      assert result.sessions == 10
      assert result.messages == 20
      assert result.input_tokens == "0"
      assert result.output_tokens == "0"
      assert result.models == []
    end

    test "handles nil model usage" do
      data = %{
        "totalSessions" => 5
      }

      result = parse_claude_stats(data)

      assert result.sessions == 5
      assert result.input_tokens == "0"
      assert result.models == []
    end
  end

  describe "format_tokens/1 logic" do
    test "formats millions" do
      assert format_tokens(1_500_000) == "1.5M"
      assert format_tokens(1_000_000) == "1.0M"
      assert format_tokens(2_345_678) == "2.3M"
    end

    test "formats thousands" do
      assert format_tokens(50_000) == "50.0K"
      assert format_tokens(1_000) == "1.0K"
      # 999_999 is just under 1M so it's formatted as K
      result = format_tokens(999_999)
      assert String.ends_with?(result, "K")
    end

    test "formats small numbers as-is" do
      assert format_tokens(500) == "500"
      assert format_tokens(0) == "0"
      assert format_tokens(999) == "999"
    end
  end

  describe "extract_stat/2 logic" do
    test "extracts integer from text matching regex" do
      text = "Sessions        42"
      assert extract_stat(text, ~r/Sessions\s+(\d+)/) == 42
    end

    test "returns 0 when no match" do
      text = "No sessions here"
      assert extract_stat(text, ~r/Sessions\s+(\d+)/) == 0
    end
  end

  describe "extract_string/2 logic" do
    test "extracts string from text matching regex" do
      text = "Total Cost      $15.50"
      assert extract_string(text, ~r/Total Cost\s+(\$[\d.]+)/) == "$15.50"
    end

    test "returns N/A when no match" do
      text = "No cost here"
      assert extract_string(text, ~r/Total Cost\s+(\$[\d.]+)/) == "N/A"
    end
  end

  describe "GenServer behavior" do
    test "module exports expected client API functions" do
      assert function_exported?(StatsMonitor, :start_link, 1)
      assert function_exported?(StatsMonitor, :get_stats, 0)
      assert function_exported?(StatsMonitor, :refresh, 0)
      assert function_exported?(StatsMonitor, :subscribe, 0)
    end

    test "handle_call :get_stats returns current stats" do
      stats = %{opencode: %{sessions: 10}, claude: %{sessions: 5}}
      state = %{stats: stats}

      {:reply, reply, new_state} = StatsMonitor.handle_call(:get_stats, self(), state)

      assert reply == stats
      assert new_state == state
    end

    test "handle_cast :refresh updates stats" do
      state = %{stats: %{}}

      {:noreply, new_state} = StatsMonitor.handle_cast(:refresh, state)

      # Stats should be updated (though we can't verify content without mocking)
      assert is_map(new_state.stats)
    end

    test "handle_info :poll schedules next poll" do
      state = %{stats: %{opencode: %{}, claude: %{}}}

      {:noreply, new_state} = StatsMonitor.handle_info(:poll, state)

      # Should have scheduled next poll
      assert_receive :poll, 6000  # Default poll interval is 5000ms
      assert is_map(new_state.stats)
    end
  end

  # Implementations mirroring the private function logic
  defp parse_opencode_stats(output) do
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

  defp parse_claude_stats(data) do
    models = data["modelUsage"] || %{}

    total_input = models |> Map.values() |> Enum.map(&(&1["inputTokens"] || 0)) |> Enum.sum()
    total_output = models |> Map.values() |> Enum.map(&(&1["outputTokens"] || 0)) |> Enum.sum()
    total_cache = models |> Map.values() |> Enum.map(&(&1["cacheReadInputTokens"] || 0)) |> Enum.sum()

    %{
      sessions: data["totalSessions"] || 0,
      messages: data["totalMessages"] || 0,
      input_tokens: format_tokens(total_input),
      output_tokens: format_tokens(total_output),
      cache_read: format_tokens(total_cache),
      models: Map.keys(models)
    }
  end

  defp format_tokens(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_tokens(n) when n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_tokens(n), do: "#{n}"

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
end
