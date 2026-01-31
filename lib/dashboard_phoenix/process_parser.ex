defmodule DashboardPhoenix.ProcessParser do
  @moduledoc """
  Shared module for parsing `ps aux` output into structured process data.
  Consolidates duplicated process parsing logic used across multiple modules.
  """

  require Logger

  alias DashboardPhoenix.CommandRunner

  @cli_timeout_ms 10_000

  @doc """
  Execute `ps aux` and return parsed process list.

  ## Options
  - `:sort` - ps sort option (default: "-pcpu")
  - `:filter` - function to filter process lines
  - `:limit` - maximum number of processes to return
  - `:timeout` - command timeout in milliseconds

  ## Examples

      iex> ProcessParser.list_processes(filter: &String.contains?(&1, "opencode"))
      [%{pid: "1234", cpu: 15.2, ...}]

      iex> ProcessParser.list_processes(sort: "-start_time", limit: 5)
      [%{pid: "5678", cpu: 2.1, ...}]
  """
  def list_processes(opts \\ []) do
    sort_option = Keyword.get(opts, :sort, "-pcpu")
    filter_fn = Keyword.get(opts, :filter, fn _ -> true end)
    limit = Keyword.get(opts, :limit, nil)
    timeout = Keyword.get(opts, :timeout, @cli_timeout_ms)

    case CommandRunner.run("ps", ["aux", "--sort=#{sort_option}"], timeout: timeout) do
      {:ok, output} ->
        output
        |> String.split("\n")
        |> Enum.drop(1)  # Skip header line
        |> Enum.filter(filter_fn)
        |> maybe_limit(limit)
        |> Enum.map(&parse_process_line/1)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("Failed to list processes: #{inspect(reason)}")
        []
    end
  end

  @doc """
  Parse a single ps aux output line into a process map.

  Returns a map with standardized keys:
  - `:user` - process owner
  - `:pid` - process ID (string)
  - `:cpu` - CPU usage (float)
  - `:mem` - memory usage (float) 
  - `:vsz` - virtual memory size
  - `:rss` - resident set size
  - `:tty` - controlling terminal
  - `:stat` - process state
  - `:start` - start time
  - `:time` - CPU time
  - `:command` - full command line

  Returns `nil` if line cannot be parsed.
  """
  def parse_process_line(line) when is_binary(line) do
    parts = String.split(line, ~r/\s+/, parts: 11)
    
    case parts do
      [user, pid, cpu, mem, vsz, rss, tty, stat, start, time, command | _] ->
        %{
          user: user,
          pid: pid,
          cpu: parse_float(cpu),
          mem: parse_float(mem),
          vsz: vsz,
          rss: rss,
          tty: tty,
          stat: stat,
          start: start,
          time: time,
          command: command
        }
      _ ->
        nil
    end
  end
  def parse_process_line(_), do: nil

  @doc """
  Convert process state string to a readable status.

  ## Examples

      iex> ProcessParser.derive_status("R", 25.5)
      "busy"

      iex> ProcessParser.derive_status("S", 2.1)
      "idle"

      iex> ProcessParser.derive_status("Z", 0.0)
      "zombie"
  """
  def derive_status(stat, cpu \\ 0.0) when is_binary(stat) and is_number(cpu) do
    cond do
      String.contains?(stat, "Z") -> "zombie"    # Zombie process
      String.contains?(stat, "T") -> "stopped"   # Stopped by signal
      String.contains?(stat, "X") -> "dead"      # Dead
      String.contains?(stat, "R") -> "busy"      # Actually running on CPU
      String.contains?(stat, ["S", "D"]) and cpu > 5.0 -> "busy"   # Sleeping but recently active
      String.contains?(stat, ["S", "D"]) -> "idle"  # Sleeping, low CPU = waiting
      true -> "running"
    end
  end

  @doc """
  Parse CPU or memory percentage string to float.

  ## Examples

      iex> ProcessParser.parse_float("15.2")
      15.2

      iex> ProcessParser.parse_float("invalid")
      0.0
  """
  def parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {val, _} -> val
      :error -> 0.0
    end
  end
  def parse_float(_), do: 0.0

  @doc """
  Format RSS memory value from KB to human readable format.

  ## Examples

      iex> ProcessParser.format_memory("1048576")
      "1.0 GB"

      iex> ProcessParser.format_memory("2048")
      "2.0 MB"
  """
  def format_memory(rss_kb) when is_binary(rss_kb) do
    case Integer.parse(rss_kb) do
      {kb, _} when kb >= 1_000_000 -> "#{Float.round(kb / 1_000_000, 1)} GB"
      {kb, _} when kb >= 1_000 -> "#{Float.round(kb / 1_000, 1)} MB"
      {kb, _} -> "#{kb} KB"
      :error -> "N/A"
    end
  end
  def format_memory(_), do: "N/A"

  @doc """
  Generate consistent process names from PID using adjective-noun pattern.

  ## Examples

      iex> ProcessParser.generate_name("1234")
      "keen-wave"
  """
  def generate_name(pid) when is_binary(pid) do
    adjectives = ~w(swift calm bold keen warm cool soft loud fast slow wild mild dark pale deep)
    nouns = ~w(beam node code wave pulse spark flame storm cloud river stone forge)
    
    case Integer.parse(pid) do
      {pid_int, _} ->
        adj = Enum.at(adjectives, rem(pid_int, length(adjectives)))
        noun = Enum.at(nouns, rem(div(pid_int, 100), length(nouns)))
        "#{adj}-#{noun}"
      _ ->
        "unknown-process"
    end
  end
  def generate_name(_), do: "unknown-process"

  @doc """
  Truncate command string and remove long flags for readability.
  """
  def truncate_command(command, max_length \\ 80)
  def truncate_command(command, max_length) when is_binary(command) do
    command
    |> String.slice(0, max_length)
    |> String.replace(~r/--[a-zA-Z]+=\S+/, "")  # Remove long flags
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end
  def truncate_command(_, _), do: ""

  @doc """
  Check if a process line contains any of the given patterns (case-insensitive).

  ## Examples

      iex> ProcessParser.contains_patterns?("opencode session start", ["opencode", "claude"])
      true

      iex> ProcessParser.contains_patterns?("vim editor", ["opencode", "claude"])  
      false
  """
  def contains_patterns?(line, patterns) when is_binary(line) and is_list(patterns) do
    line_lower = String.downcase(line)
    Enum.any?(patterns, &String.contains?(line_lower, &1))
  end
  def contains_patterns?(_, _), do: false

  # Private helpers

  defp maybe_limit(list, nil), do: list
  defp maybe_limit(list, limit) when is_integer(limit), do: Enum.take(list, limit)
end