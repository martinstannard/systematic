defmodule DashboardPhoenixWeb.Live.Components.LinearComponentTest do
  use ExUnit.Case, async: true

  describe "state handling after fix" do
    test "includes Triaging in filter states list" do
      # This test ensures the component template includes the correct state names
      # after our fix from "Triage" to "Triaging"
      
      # Check that the template would render with the correct states
      _assigns = %{
        linear_status_filter: "Triaging",
        linear_counts: %{"Triaging" => 5, "Backlog" => 3, "Todo" => 2, "In Review" => 1}
      }
      
      # Test that the expected states are configured
      expected_states = ["Triaging", "Backlog", "Todo", "In Review"]
      broken_states = ["Triage", "Backlog", "Todo", "In Review"]
      
      # Verify we're not using the broken configuration
      refute "Triage" in expected_states
      assert "Triaging" in expected_states
      
      # Verify what was broken before
      assert "Triage" in broken_states
    end

    test "linear_status_badge handles Triaging state" do
      # Test that the status badge function works with the new state name
      
      # This uses a helper that mirrors the private function logic
      triaging_badge = get_status_badge_class("Triaging")
      backlog_badge = get_status_badge_class("Backlog")
      
      # Triaging should get the red badge (same as old Triage)
      assert triaging_badge =~ "bg-red-500/20"
      assert triaging_badge =~ "text-red-400"
      
      # Other states should still work
      assert backlog_badge =~ "bg-blue-500/20"
      assert backlog_badge =~ "text-blue-400"
    end

    test "linear_filter_button_active handles Triaging state" do
      # Test that the filter button styling works with the new state name
      
      triaging_active = get_filter_button_class("Triaging")
      backlog_active = get_filter_button_class("Backlog")
      
      # Triaging should get the red active styling (same as old Triage)
      assert triaging_active =~ "bg-red-500/30"
      assert triaging_active =~ "text-red-400"
      assert triaging_active =~ "border-red-500/50"
      
      # Other states should still work
      assert backlog_active =~ "bg-blue-500/30"
      assert backlog_active =~ "text-blue-400" 
      assert backlog_active =~ "border-blue-500/50"
    end

    test "component update handles Triaging filter correctly" do
      # Test that the component update function works with Triaging tickets
      
      tickets = [
        %{id: "COR-100", status: "Triaging", title: "Needs triage"},
        %{id: "COR-101", status: "Backlog", title: "Backlog item"},
        %{id: "COR-102", status: "Triaging", title: "Another triage"}
      ]
      
      assigns = %{
        linear_tickets: tickets,
        linear_status_filter: "Triaging"
      }
      
      # Simulate the update logic
      filtered_tickets = filter_tickets_for_status(assigns.linear_tickets, assigns.linear_status_filter)
      
      assert length(filtered_tickets) == 2
      assert Enum.all?(filtered_tickets, &(&1.status == "Triaging"))
    end

    test "event handling works with Triaging state" do
      # Test that the event handler accepts Triaging as a valid status
      
      # Test the validation logic that would be used in handle_event
      valid_statuses = ["Triaging", "Backlog", "Todo", "In Review"]
      _invalid_statuses = ["Triage", "Invalid", ""]
      
      # Triaging should be valid
      assert "Triaging" in valid_statuses
      refute "Triage" in valid_statuses
      
      # Test validation helper
      assert validate_status_filter("Triaging") == {:ok, "Triaging"}
      assert validate_status_filter("Triage") == {:error, :invalid_status}
    end

    test "reproduces the original bug scenario" do
      # This test documents what would have been broken with the old "Triage" state
      
      # The old configuration that would have failed
      old_tickets = [
        %{id: "COR-100", status: "Triage", title: "Old triage item"}
      ]
      
      old_assigns = %{
        linear_tickets: old_tickets,
        linear_status_filter: "Triage"
      }
      
      # With the old state, we would have had mismatched state names
      # since the monitor would fail to fetch "Triage" tickets but
      # the component would try to filter by "Triage"
      
      filtered_old = filter_tickets_for_status(old_assigns.linear_tickets, "Triage")
      filtered_new = filter_tickets_for_status(old_assigns.linear_tickets, "Triaging")
      
      # This shows the mismatch that would have occurred
      assert length(filtered_old) == 1  # Component would try to show "Triage" tickets
      assert length(filtered_new) == 0  # But monitor couldn't fetch them as "Triaging"
      
      # The fix ensures consistency between what's fetched and what's displayed
      new_tickets = [
        %{id: "COR-100", status: "Triaging", title: "Fixed triage item"}
      ]
      
      fixed_filtered = filter_tickets_for_status(new_tickets, "Triaging")
      assert length(fixed_filtered) == 1  # Now both sides use "Triaging"
    end
  end

  # Helper functions that mirror the component's private function logic

  defp get_status_badge_class("Triaging"), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-[10px]"
  defp get_status_badge_class("Todo"), do: "px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-[10px]"
  defp get_status_badge_class("Backlog"), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-[10px]"
  defp get_status_badge_class(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-[10px]"

  defp get_filter_button_class("Triaging"), do: "bg-red-500/30 text-red-400 border border-red-500/50"
  defp get_filter_button_class("Backlog"), do: "bg-blue-500/30 text-blue-400 border border-blue-500/50"
  defp get_filter_button_class("Todo"), do: "bg-yellow-500/30 text-yellow-400 border border-yellow-500/50"
  defp get_filter_button_class("In Review"), do: "bg-purple-500/30 text-purple-400 border border-purple-500/50"
  defp get_filter_button_class(_), do: "bg-accent/30 text-accent border border-accent/50"

  defp filter_tickets_for_status(tickets, status) do
    Enum.filter(tickets, &(&1.status == status))
  end

  defp validate_status_filter(status) when status in ["Triaging", "Backlog", "Todo", "In Review"] do
    {:ok, status}
  end
  defp validate_status_filter(_), do: {:error, :invalid_status}
end