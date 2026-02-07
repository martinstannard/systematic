#!/usr/bin/env elixir

# Test the chainlink parsing logic directly

defmodule TestChainlinkParse do
  def parse_issue_line(line) do
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

  def test_line(line) do
    IO.puts("Testing line: #{inspect(line)}")
    result = parse_issue_line(line)
    IO.puts("Result: #{inspect(result)}")
    IO.puts("")
  end
end

# Test with real chainlink output
lines = [
  "#73   [open]   Perf: Reduce external CLI command ove... medium   2026-02-01",
  "#72   [open]   Reliability: Add timeouts to all GenS... medium   2026-02-01",
  "#71   [open]   Perf: Replace blocking GenServer call... medium   2026-02-01",
  "#70   [open]   Perf: Optimize SessionBridge file I/O... high     2026-02-01"
]

Enum.each(lines, &TestChainlinkParse.test_line/1)
