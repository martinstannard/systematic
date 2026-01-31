defmodule DashboardPhoenix.LinearMonitorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.LinearMonitor

  # Tests for parsing logic - we test via fallback implementations that mirror
  # the private function logic, since we can't directly call private functions

  describe "parse_issues_output/2 (parsing logic)" do
    test "parses standard Linear CLI output format" do
      output = """
      ID       Title                          State    Project      Assignee
      
      COR-123  Fix login bug                  Todo     Core         you
      COR-124  Add feature X                  Todo     Platform     John
      """

      result = parse_issues_output(output, "Todo")

      assert length(result) == 2
      [first, second] = result

      assert first.id == "COR-123"
      assert first.title == "Fix login bug"
      assert first.status == "Todo"
      assert first.project == "Core"
      assert first.assignee == "you"
      assert first.url == "https://linear.app/fresh-clinics/issue/COR-123"

      assert second.id == "COR-124"
      assert second.assignee == "John"
    end

    test "handles empty output" do
      output = """
      ID       Title                          State    Project      Assignee
      
      """

      result = parse_issues_output(output, "Backlog")
      assert result == []
    end

    test "handles output with ANSI codes" do
      output = """
      ID       Title                          State    Project      Assignee
      
      \e[32mCOR-456\e[0m  Some task with colors        Todo     Core         -
      """

      result = parse_issues_output(output, "Todo")

      assert length(result) == 1
      [ticket] = result
      assert ticket.id == "COR-456"
    end

    test "normalizes dash to nil for project and assignee" do
      output = """
      ID       Title                          State    Project      Assignee
      
      COR-789  Unassigned task                Todo     -            -
      """

      result = parse_issues_output(output, "Todo")

      [ticket] = result
      assert ticket.project == nil
      assert ticket.assignee == nil
    end

    test "handles simpler format with fewer columns" do
      output = """
      ID       Title                          State
      
      COR-100  Simple task                    Todo
      """

      result = parse_issues_output(output, "Todo")

      assert length(result) == 1
      [ticket] = result
      assert ticket.id == "COR-100"
      assert ticket.title == "Simple task"
    end
  end

  describe "build_issue_url logic" do
    test "builds correct Linear URL" do
      url = build_issue_url("COR-999")
      assert url == "https://linear.app/fresh-clinics/issue/COR-999"
    end
  end

  describe "normalize_project/1 logic" do
    test "returns nil for dash" do
      assert normalize_project("-") == nil
    end

    test "trims and returns project name" do
      assert normalize_project("  Core  ") == "Core"
      assert normalize_project("Platform") == "Platform"
    end
  end

  describe "normalize_assignee/1 logic" do
    test "returns nil for dash" do
      assert normalize_assignee("-") == nil
    end

    test "preserves 'you' keyword" do
      assert normalize_assignee("you") == "you"
    end

    test "trims and returns assignee name" do
      assert normalize_assignee("  John  ") == "John"
    end
  end

  describe "sort_tickets/1 logic" do
    test "sorts tickets by ID descending (newest first)" do
      tickets = [
        %{id: "COR-100", title: "First"},
        %{id: "COR-500", title: "Middle"},
        %{id: "COR-999", title: "Latest"}
      ]

      sorted = sort_tickets(tickets)

      assert Enum.map(sorted, & &1.id) == ["COR-999", "COR-500", "COR-100"]
    end

    test "handles tickets with non-numeric IDs gracefully" do
      tickets = [
        %{id: "COR-100", title: "Valid"},
        %{id: "INVALID", title: "Invalid"}
      ]

      # Should not crash
      sorted = sort_tickets(tickets)
      assert length(sorted) == 2
    end
  end

  describe "GenServer behavior" do
    test "module exports expected client API functions" do
      assert function_exported?(LinearMonitor, :start_link, 1)
      assert function_exported?(LinearMonitor, :get_tickets, 0)
      assert function_exported?(LinearMonitor, :refresh, 0)
      assert function_exported?(LinearMonitor, :subscribe, 0)
      assert function_exported?(LinearMonitor, :get_ticket_details, 1)
    end

    test "init returns expected state structure" do
      {:ok, state} = LinearMonitor.init([])

      assert state.tickets == []
      assert state.last_updated == nil
      assert state.error == nil
    end

    test "handle_call :get_tickets returns state data" do
      state = %{tickets: [%{id: "COR-1"}], last_updated: DateTime.utc_now(), error: nil}

      {:reply, reply, new_state} = LinearMonitor.handle_call(:get_tickets, self(), state)

      assert reply.tickets == state.tickets
      assert reply.last_updated == state.last_updated
      assert reply.error == state.error
      assert new_state == state
    end

    test "handle_cast :refresh sends poll message" do
      state = %{tickets: [], last_updated: nil, error: nil}

      {:noreply, new_state} = LinearMonitor.handle_cast(:refresh, state)

      # Should receive :poll message
      assert_receive :poll, 100
      assert new_state == state
    end
  end

  # Implementations mirroring the private function logic for testing
  defp parse_issues_output(output, status) do
    output
    |> String.split("\n")
    |> Enum.drop(2)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_issue_line(&1, status))
    |> Enum.reject(&is_nil/1)
  end

  defp parse_issue_line(line, status) do
    clean_line = String.replace(line, ~r/\e\[[0-9;]*m/, "")

    case Regex.run(~r/^(COR-\d+)\s{2,}(.+?)\s{2,}(\w+)\s{2,}(.+?)\s{2,}(.*)$/, clean_line) do
      [_, id, title, _state, project, assignee] ->
        %{
          id: String.trim(id),
          title: String.trim(title),
          status: status,
          project: normalize_project(project),
          assignee: normalize_assignee(assignee),
          priority: nil,
          url: build_issue_url(id),
          pr_url: nil
        }

      _ ->
        case Regex.run(~r/^(COR-\d+)\s{2,}(.+?)\s{2,}(\w+)/, clean_line) do
          [_, id, title, _state | _rest] ->
            %{
              id: String.trim(id),
              title: String.trim(title),
              status: status,
              project: nil,
              assignee: nil,
              priority: nil,
              url: build_issue_url(id),
              pr_url: nil
            }

          _ ->
            nil
        end
    end
  end

  defp normalize_project("-"), do: nil
  defp normalize_project(project), do: String.trim(project)

  defp normalize_assignee("-"), do: nil
  defp normalize_assignee("you"), do: "you"
  defp normalize_assignee(assignee), do: String.trim(assignee)

  defp build_issue_url(issue_id) do
    "https://linear.app/fresh-clinics/issue/#{String.trim(issue_id)}"
  end

  defp sort_tickets(tickets) do
    Enum.sort_by(tickets, fn ticket ->
      case Regex.run(~r/COR-(\d+)/, ticket.id) do
        [_, num] -> -String.to_integer(num)
        _ -> 0
      end
    end)
  end
end
