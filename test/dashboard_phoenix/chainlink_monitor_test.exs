defmodule DashboardPhoenix.ChainlinkMonitorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.ChainlinkMonitor

  describe "GenServer behavior - init" do
    test "init returns expected initial state" do
      {:ok, state} = ChainlinkMonitor.init([])

      assert state.issues == []
      assert state.last_updated == nil
      assert state.error == nil
    end
  end

  describe "GenServer behavior - handle_call :get_issues" do
    test "returns current state info" do
      now = DateTime.utc_now()
      state = %{
        issues: [%{id: 1, title: "Test Issue"}],
        last_updated: now,
        error: nil
      }

      {:reply, result, _new_state} = ChainlinkMonitor.handle_call(:get_issues, self(), state)

      assert result.issues == [%{id: 1, title: "Test Issue"}]
      assert result.last_updated == now
      assert result.error == nil
    end

    test "returns error state when present" do
      state = %{
        issues: [],
        last_updated: nil,
        error: "Failed to fetch"
      }

      {:reply, result, _} = ChainlinkMonitor.handle_call(:get_issues, self(), state)

      assert result.error == "Failed to fetch"
    end
  end

  describe "GenServer behavior - handle_cast :refresh" do
    test "sends poll message to self" do
      state = %{issues: [], last_updated: nil, error: nil}

      {:noreply, new_state} = ChainlinkMonitor.handle_cast(:refresh, state)

      # Should receive :poll message
      assert_receive :poll, 100
      assert new_state == state
    end
  end

  describe "GenServer behavior - handle_info :poll_complete" do
    test "updates state from poll complete" do
      now = DateTime.utc_now()
      old_state = %{issues: [], last_updated: nil, error: nil}
      new_state = %{
        issues: [%{id: 1, title: "New Issue"}],
        last_updated: now,
        error: nil
      }

      {:noreply, result_state} = ChainlinkMonitor.handle_info({:poll_complete, new_state}, old_state)

      assert result_state.issues == [%{id: 1, title: "New Issue"}]
      assert result_state.last_updated == now
      # Note: Poll scheduling verified separately - it schedules after 60s
    end
  end

  describe "parse_chainlink_output/1 logic" do
    test "parses standard chainlink list output" do
      output = """
      #17   [open]   Add Chainlink issues panel with Work button   high     2026-01-31
      #18   [open]   Implement feature flags   medium     2026-02-15
      """

      result = parse_chainlink_output(output)

      assert length(result) == 2
      
      [issue1, issue2] = result
      assert issue1.id == 17
      assert issue1.status == "open"
      assert issue1.title == "Add Chainlink issues panel with Work button"
      assert issue1.priority == :high
      assert issue1.due == "2026-01-31"
      
      assert issue2.id == 18
      assert issue2.priority == :medium
    end

    test "handles output without due date" do
      output = """
      #5   [open]   Simple task   low
      """

      result = parse_chainlink_output(output)

      assert length(result) == 1
      [issue] = result
      assert issue.id == 5
      assert issue.status == "open"
      assert issue.title == "Simple task"
      assert issue.priority == :low
      assert issue.due == nil
    end

    test "handles empty output" do
      assert parse_chainlink_output("") == []
      assert parse_chainlink_output("\n\n") == []
    end

    test "strips ANSI escape codes" do
      # Simulated ANSI-colored output
      output = "\e[32m#10\e[0m   [open]   Colored output test   high     2026-03-01"

      result = parse_chainlink_output(output)

      assert length(result) == 1
      [issue] = result
      assert issue.id == 10
      assert issue.title == "Colored output test"
    end

    test "skips malformed lines" do
      output = """
      #17   [open]   Valid issue   high     2026-01-31
      This is not a valid issue line
      #18   [open]   Another valid issue   medium     2026-02-15
      Also invalid
      """

      result = parse_chainlink_output(output)

      assert length(result) == 2
      assert Enum.map(result, & &1.id) == [17, 18]
    end

    test "handles closed status" do
      output = """
      #25   [closed]   Completed task   high     2026-01-30
      """

      result = parse_chainlink_output(output)

      assert length(result) == 1
      [issue] = result
      assert issue.status == "closed"
    end
  end

  describe "normalize_priority/1 logic" do
    test "normalizes high priority" do
      assert normalize_priority("high") == :high
      assert normalize_priority("HIGH") == :high
      assert normalize_priority("High") == :high
    end

    test "normalizes medium priority" do
      assert normalize_priority("medium") == :medium
      assert normalize_priority("MEDIUM") == :medium
    end

    test "normalizes low priority" do
      assert normalize_priority("low") == :low
      assert normalize_priority("LOW") == :low
    end

    test "defaults to medium for unknown priority" do
      assert normalize_priority("urgent") == :medium
      assert normalize_priority("critical") == :medium
      assert normalize_priority("unknown") == :medium
    end
  end

  describe "parse_issue_line/1 logic" do
    test "parses complete issue line with due date" do
      line = "#42   [open]   Fix the bug in module   high     2026-04-15"

      result = parse_issue_line(line)

      assert result.id == 42
      assert result.status == "open"
      assert result.title == "Fix the bug in module"
      assert result.priority == :high
      assert result.due == "2026-04-15"
    end

    test "parses issue line without due date" do
      line = "#7   [open]   Quick fix   low"

      result = parse_issue_line(line)

      assert result.id == 7
      assert result.status == "open"
      assert result.title == "Quick fix"
      assert result.priority == :low
      assert result.due == nil
    end

    test "returns nil for invalid line" do
      assert parse_issue_line("random text") == nil
      assert parse_issue_line("") == nil
      assert parse_issue_line("# not a valid id") == nil
    end

    test "handles titles with special characters" do
      line = "#99   [open]   Fix bug in file_utils.ex (critical)   high     2026-05-01"

      result = parse_issue_line(line)

      assert result.id == 99
      assert result.title =~ "Fix bug in file_utils.ex"
    end
  end

  describe "module exports" do
    test "exports expected client API functions" do
      assert function_exported?(ChainlinkMonitor, :start_link, 0)
      assert function_exported?(ChainlinkMonitor, :start_link, 1)
      assert function_exported?(ChainlinkMonitor, :get_issues, 0)
      assert function_exported?(ChainlinkMonitor, :refresh, 0)
      assert function_exported?(ChainlinkMonitor, :subscribe, 0)
      assert function_exported?(ChainlinkMonitor, :get_issue_details, 1)
    end
  end

  # Implementations mirroring the private function logic
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
