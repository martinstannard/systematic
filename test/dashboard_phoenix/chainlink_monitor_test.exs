defmodule DashboardPhoenix.ChainlinkMonitorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.ChainlinkMonitor

  describe "GenServer behavior - init" do
    # Note: We can't easily test init directly because it creates an ETS table
    # that conflicts with the running GenServer. Test via the public API instead.
    test "GenServer starts successfully" do
      # The monitor is started as part of the application
      # Just verify we can call its public API
      result = ChainlinkMonitor.get_issues()
      
      assert is_map(result)
      assert Map.has_key?(result, :issues)
      assert Map.has_key?(result, :last_updated)
      assert Map.has_key?(result, :error)
    end
  end

  describe "public API - get_issues (ETS-based)" do
    # Note: Ticket #71 replaced GenServer.call with direct ETS reads
    # These tests verify the public API still works correctly
    test "returns expected structure" do
      result = ChainlinkMonitor.get_issues()

      assert is_map(result)
      assert is_list(result.issues)
      assert Map.has_key?(result, :last_updated)
      assert Map.has_key?(result, :error)
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

      result = ChainlinkMonitor.parse_chainlink_output_for_test(output)

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

      result = ChainlinkMonitor.parse_chainlink_output_for_test(output)

      assert length(result) == 1
      [issue] = result
      assert issue.id == 5
      assert issue.status == "open"
      assert issue.title == "Simple task"
      assert issue.priority == :low
      assert issue.due == nil
    end

    test "handles empty output" do
      assert ChainlinkMonitor.parse_chainlink_output_for_test("") == []
      assert ChainlinkMonitor.parse_chainlink_output_for_test("\n\n") == []
    end

    test "strips ANSI escape codes" do
      # Simulated ANSI-colored output
      output = "\e[32m#10\e[0m   [open]   Colored output test   high     2026-03-01"

      result = ChainlinkMonitor.parse_chainlink_output_for_test(output)

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

      result = ChainlinkMonitor.parse_chainlink_output_for_test(output)

      assert length(result) == 2
      assert Enum.map(result, & &1.id) == [17, 18]
    end

    test "handles closed status" do
      output = """
      #25   [closed]   Completed task   high     2026-01-30
      """

      result = ChainlinkMonitor.parse_chainlink_output_for_test(output)

      assert length(result) == 1
      [issue] = result
      assert issue.status == "closed"
    end

    test "parses real chainlink output with truncated titles" do
      output = """
      #73   [open]   Perf: Reduce external CLI command ove... medium   2026-02-01
      #70   [open]   Perf: Optimize SessionBridge file I/O... high     2026-02-01
      """

      result = ChainlinkMonitor.parse_chainlink_output_for_test(output)

      assert length(result) == 2
      
      [issue1, issue2] = result
      assert issue1.id == 73
      assert issue1.status == "open"
      assert issue1.title == "Perf: Reduce external CLI command ove..."
      assert issue1.priority == :medium
      assert issue1.due == "2026-02-01"
      
      assert issue2.id == 70
      assert issue2.status == "open"
      assert issue2.title == "Perf: Optimize SessionBridge file I/O..."
      assert issue2.priority == :high
      assert issue2.due == "2026-02-01"
    end
  end

  describe "normalize_priority/1 logic" do
    test "normalizes high priority" do
      assert ChainlinkMonitor.normalize_priority_for_test("high") == :high
      assert ChainlinkMonitor.normalize_priority_for_test("HIGH") == :high
      assert ChainlinkMonitor.normalize_priority_for_test("High") == :high
    end

    test "normalizes medium priority" do
      assert ChainlinkMonitor.normalize_priority_for_test("medium") == :medium
      assert ChainlinkMonitor.normalize_priority_for_test("MEDIUM") == :medium
    end

    test "normalizes low priority" do
      assert ChainlinkMonitor.normalize_priority_for_test("low") == :low
      assert ChainlinkMonitor.normalize_priority_for_test("LOW") == :low
    end

    test "defaults to medium for unknown priority" do
      assert ChainlinkMonitor.normalize_priority_for_test("urgent") == :medium
      assert ChainlinkMonitor.normalize_priority_for_test("critical") == :medium
      assert ChainlinkMonitor.normalize_priority_for_test("unknown") == :medium
    end
  end

  describe "parse_issue_line/1 logic" do
    test "parses complete issue line with due date" do
      line = "#42   [open]   Fix the bug in module   high     2026-04-15"

      result = ChainlinkMonitor.parse_issue_line_for_test(line)

      assert result.id == 42
      assert result.status == "open"
      assert result.title == "Fix the bug in module"
      assert result.priority == :high
      assert result.due == "2026-04-15"
    end

    test "parses issue line without due date" do
      line = "#7   [open]   Quick fix   low"

      result = ChainlinkMonitor.parse_issue_line_for_test(line)

      assert result.id == 7
      assert result.status == "open"
      assert result.title == "Quick fix"
      assert result.priority == :low
      assert result.due == nil
    end

    test "returns nil for invalid line" do
      assert ChainlinkMonitor.parse_issue_line_for_test("random text") == nil
      assert ChainlinkMonitor.parse_issue_line_for_test("") == nil
      assert ChainlinkMonitor.parse_issue_line_for_test("# not a valid id") == nil
    end

    test "handles titles with special characters" do
      line = "#99   [open]   Fix bug in file_utils.ex (critical)   high     2026-05-01"

      result = ChainlinkMonitor.parse_issue_line_for_test(line)

      assert result.id == 99
      assert result.title =~ "Fix bug in file_utils.ex"
    end

    test "parses real chainlink output with truncated titles correctly" do
      line = "#70   [open]   Perf: Optimize SessionBridge file I/O... high     2026-02-01"

      result = ChainlinkMonitor.parse_issue_line_for_test(line)

      assert result.id == 70
      assert result.status == "open"
      assert result.title == "Perf: Optimize SessionBridge file I/O..."
      assert result.priority == :high
      assert result.due == "2026-02-01"
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
end
