#!/usr/bin/env elixir

line = "#70   [open]   Perf: Optimize SessionBridge file I/O... high     2026-02-01"

IO.puts("Line length: #{String.length(line)}")
IO.puts("Raw bytes: #{inspect(line, binaries: :as_strings)}")

# Let's check each character position around where we expect priority/date
IO.puts("\nLast 20 characters:")
last_20 = String.slice(line, -20..-1)
for {char, index} <- Enum.with_index(String.to_charlist(last_20)) do
  IO.puts("#{index + (String.length(line) - 20)}: #{inspect(<<char>>)} (#{char})")
end

# Test different regex patterns
patterns = [
  ~r/^#(\d+)\s+\[(\w+)\]\s+(.+?)\s{2,}(\w+)\s+(\d{4}-\d{2}-\d{2})?/,  # original
  ~r/^#(\d+)\s+\[(\w+)\]\s+(.+?)\s+(\w+)\s+(\d{4}-\d{2}-\d{2})$/,     # exact spacing with date required
  ~r/^#(\d+)\s+\[(\w+)\]\s+(.+)\s+(\w+)\s+(\d{4}-\d{2}-\d{2})$/,      # greedy title with date required
]

for {pattern, index} <- Enum.with_index(patterns) do
  IO.puts("\nPattern #{index + 1}:")
  case Regex.run(pattern, line) do
    nil -> IO.puts("No match")
    matches -> 
      IO.puts("Matches: #{inspect(matches)}")
      [_, id, status, title, priority | rest] = matches
      IO.puts("  ID: #{id}")
      IO.puts("  Status: #{status}")  
      IO.puts("  Title: #{title}")
      IO.puts("  Priority: #{priority}")
      IO.puts("  Rest: #{inspect(rest)}")
  end
end