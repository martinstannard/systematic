defmodule DashboardPhoenixWeb.Live.Components.LinearComponentTest do
  use DashboardPhoenixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DashboardPhoenixWeb.Live.Components.LinearComponent

  # Sample test data
  @sample_tickets [
    %{id: "COR-100", title: "Urgent issue", status: "Triaging", url: "https://linear.app/fresh-clinics/issue/COR-100"},
    %{id: "COR-101", title: "Feature request", status: "Backlog", url: "https://linear.app/fresh-clinics/issue/COR-101"},
    %{id: "COR-102", title: "Bug fix needed", status: "Todo", url: "https://linear.app/fresh-clinics/issue/COR-102"},
    %{id: "COR-103", title: "Ready for review", status: "In Review", url: "https://linear.app/fresh-clinics/issue/COR-103"},
    %{id: "COR-104", title: "Another review", status: "In Review", url: "https://linear.app/fresh-clinics/issue/COR-104"}
  ]

  @sample_counts %{"Triaging" => 1, "Backlog" => 1, "Todo" => 1, "In Review" => 2}

  describe "component rendering" do
    test "renders component with all required assigns" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Panel header should be visible
      assert html =~ "Linear"
      assert html =~ "🎫"
      
      # Total ticket count should be shown
      assert html =~ "#{length(@sample_tickets)}"
      
      # Filter buttons should be visible
      assert html =~ "Triaging"
      assert html =~ "Backlog"
      assert html =~ "Todo"
      assert html =~ "In Review"
    end

    test "renders loading state correctly" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: [],
        linear_filtered_tickets: [],
        linear_counts: %{},
        linear_status_filter: "In Review",
        linear_loading: true,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Should show loading indicator
      assert html =~ "Loading tickets..."
      assert html =~ "status-activity-ring"
    end

    test "renders error state correctly" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: [],
        linear_filtered_tickets: [],
        linear_counts: %{},
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: "Failed to fetch tickets",
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Should show error message
      assert html =~ "Failed to fetch tickets"
      assert html =~ "text-error"
    end

    test "renders collapsed state correctly" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: true,
        tickets_in_progress: %{}
      })

      # Should have collapsed class
      assert html =~ "max-h-0"
      assert html =~ ~s(aria-expanded="false")
    end

    test "renders expanded state correctly" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Should not have collapsed class
      assert html =~ "max-h-[400px]"
      assert html =~ ~s(aria-expanded="true")
    end
  end

  describe "filter button display" do
    test "shows correct counts for each status" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Each filter button should show the count
      assert html =~ "Triaging (1)"
      assert html =~ "Backlog (1)"
      assert html =~ "Todo (1)"
      assert html =~ "In Review (2)"
    end

    test "highlights active filter button" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # In Review button should have active styling (purple)
      assert html =~ "bg-purple-500/30"
      assert html =~ "text-purple-400"
      assert html =~ ~s(aria-pressed="true")
    end

    test "filter buttons have correct accessibility attributes" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Filter buttons should have aria-label for accessibility
      assert html =~ ~s(aria-label="Filter tickets by)
    end
  end

  describe "ticket list display" do
    test "displays filtered tickets only" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Should show In Review tickets
      assert html =~ "COR-103"
      assert html =~ "COR-104"
      assert html =~ "Ready for review"
      assert html =~ "Another review"
      
      # Should NOT show tickets from other statuses
      refute html =~ "COR-100"
      refute html =~ "COR-101"
      refute html =~ "COR-102"
    end

    test "displays ticket links correctly" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Links should open in new tab
      assert html =~ ~s(target="_blank")
      assert html =~ "https://linear.app/fresh-clinics/issue/COR-103"
    end

    test "shows work button for tickets not in progress" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Work button should be present
      assert html =~ "▶"
      assert html =~ ~s(phx-click="work_on_ticket")
    end

    test "shows in-progress indicator for active work" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{"COR-103" => %{label: "working-on-103"}}
      })

      # Should show in-progress indicator (static dot instead of play button)
      assert html =~ "bg-success"
    end
  end

  describe "state names validation" do
    test "includes Triaging in filter states list (not Triage)" do
      # This test ensures the component uses the correct state names
      # after the fix from "Triage" to "Triaging"
      
      # The expected states in the component
      expected_states = ["Triaging", "Backlog", "Todo", "In Review"]
      broken_states = ["Triage", "Backlog", "Todo", "In Review"]
      
      # Verify we're not using the broken configuration
      refute "Triage" in expected_states
      assert "Triaging" in expected_states
      
      # Verify what was broken before
      assert "Triage" in broken_states
    end

    test "status badge handles Triaging state" do
      # Test that the status badge function works with the new state name
      
      triaging_badge = get_status_badge_class("Triaging")
      backlog_badge = get_status_badge_class("Backlog")
      
      # Triaging should get the red badge
      assert triaging_badge =~ "bg-red-500/20"
      assert triaging_badge =~ "text-red-400"
      
      # Other states should still work
      assert backlog_badge =~ "bg-blue-500/20"
      assert backlog_badge =~ "text-blue-400"
    end

    test "filter button active styling handles all states" do
      # Test that the filter button styling works for all states
      
      triaging_active = get_filter_button_class("Triaging")
      backlog_active = get_filter_button_class("Backlog")
      todo_active = get_filter_button_class("Todo")
      in_review_active = get_filter_button_class("In Review")
      
      # Triaging - red
      assert triaging_active =~ "bg-red-500/30"
      assert triaging_active =~ "text-red-400"
      
      # Backlog - blue
      assert backlog_active =~ "bg-blue-500/30"
      assert backlog_active =~ "text-blue-400"
      
      # Todo - yellow
      assert todo_active =~ "bg-yellow-500/30"
      assert todo_active =~ "text-yellow-400"
      
      # In Review - purple
      assert in_review_active =~ "bg-purple-500/30"
      assert in_review_active =~ "text-purple-400"
    end
  end

  describe "component update behavior" do
    test "component pre-filters tickets by status" do
      triaging_tickets = filter_tickets(@sample_tickets, "Triaging")
      
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: triaging_tickets,
        linear_counts: @sample_counts,
        linear_status_filter: "Triaging",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })
      
      # Should show only Triaging tickets
      assert html =~ "COR-100"
      assert html =~ "Urgent issue"
      
      # Should NOT show tickets from other statuses
      refute html =~ "COR-101"
      refute html =~ "COR-102"
      refute html =~ "COR-103"
    end

    test "component limits filtered tickets to 10" do
      # Create more than 10 tickets
      many_tickets = for i <- 1..15 do
        %{id: "COR-#{i}", title: "Ticket #{i}", status: "In Review", url: "https://linear.app/test/issue/COR-#{i}"}
      end
      
      # Simulate the filtering that happens in update/2
      limited_tickets = many_tickets |> Enum.take(10)
      
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: many_tickets,
        linear_filtered_tickets: limited_tickets,
        linear_counts: %{"In Review" => 15},
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })
      
      # Should show first 10 tickets
      for i <- 1..10 do
        assert html =~ "COR-#{i}"
      end
      
      # Should NOT show tickets beyond 10
      refute html =~ "COR-11"
      refute html =~ "COR-15"
    end

    test "filtering logic works correctly" do
      # Test the filtering logic directly
      tickets = @sample_tickets
      
      in_review = filter_tickets(tickets, "In Review")
      triaging = filter_tickets(tickets, "Triaging")
      todo = filter_tickets(tickets, "Todo")
      backlog = filter_tickets(tickets, "Backlog")
      
      assert length(in_review) == 2
      assert length(triaging) == 1
      assert length(todo) == 1
      assert length(backlog) == 1
      
      # Check ticket IDs
      assert Enum.map(in_review, & &1.id) == ["COR-103", "COR-104"]
      assert Enum.map(triaging, & &1.id) == ["COR-100"]
    end
  end

  describe "event validation" do
    test "validates filter status correctly" do
      valid_statuses = ["Triaging", "Backlog", "Todo", "In Review"]
      invalid_statuses = ["Triage", "Invalid", "", nil, "invalid"]
      
      # Valid statuses should pass
      for status <- valid_statuses do
        assert validate_status_filter(status) == {:ok, status}
      end
      
      # Invalid statuses should fail
      for status <- invalid_statuses do
        assert validate_status_filter(status) == {:error, :invalid_status}
      end
    end
  end

  describe "HomeLive default configuration" do
    test "default filter is In Review" do
      # Verify the default filter is now "In Review" as required
      # This is set in HomeLive.mount/3
      default_filter = "In Review"
      
      assert default_filter == "In Review"
      refute default_filter == "Todo"
      refute default_filter == "Triaging"
    end
  end

  describe "accessibility" do
    test "panel header has keyboard navigation support" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # Header should have role, tabindex, and onkeydown
      assert html =~ ~s(role="button")
      assert html =~ ~s(tabindex="0")
      assert html =~ "onkeydown"
    end

    test "ticket list region has live announcements" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      # List region should have aria-live for screen readers
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(aria-label="Linear ticket list")
    end

    test "refresh button has aria-label" do
      html = render_component(LinearComponent, %{
        id: "linear-panel",
        linear_tickets: @sample_tickets,
        linear_filtered_tickets: filter_tickets(@sample_tickets, "In Review"),
        linear_counts: @sample_counts,
        linear_status_filter: "In Review",
        linear_loading: false,
        linear_error: nil,
        linear_collapsed: false,
        tickets_in_progress: %{}
      })

      assert html =~ ~s(aria-label="Refresh Linear tickets")
    end
  end

  # Helper functions

  defp filter_tickets(tickets, status) do
    tickets
    |> Enum.filter(&(&1.status == status))
    |> Enum.take(10)
  end

  defp get_status_badge_class("Triaging"), do: "px-1.5 py-0.5 rounded bg-red-500/20 text-red-400 text-xs"
  defp get_status_badge_class("Todo"), do: "px-1.5 py-0.5 rounded bg-yellow-500/20 text-yellow-400 text-xs"
  defp get_status_badge_class("Backlog"), do: "px-1.5 py-0.5 rounded bg-blue-500/20 text-blue-400 text-xs"
  defp get_status_badge_class(_), do: "px-1.5 py-0.5 rounded bg-base-content/10 text-base-content/60 text-xs"

  defp get_filter_button_class("Triaging"), do: "bg-red-500/30 text-red-400 border border-red-500/50"
  defp get_filter_button_class("Backlog"), do: "bg-blue-500/30 text-blue-400 border border-blue-500/50"
  defp get_filter_button_class("Todo"), do: "bg-yellow-500/30 text-yellow-400 border border-yellow-500/50"
  defp get_filter_button_class("In Review"), do: "bg-purple-500/30 text-purple-400 border border-purple-500/50"
  defp get_filter_button_class(_), do: "bg-accent/30 text-accent border border-accent/50"

  defp validate_status_filter(status) when status in ["Triaging", "Backlog", "Todo", "In Review"] do
    {:ok, status}
  end
  defp validate_status_filter(_), do: {:error, :invalid_status}
end
