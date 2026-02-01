defmodule DashboardPhoenixWeb.Live.Components.ChainlinkComponentTest do
  use DashboardPhoenixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DashboardPhoenixWeb.Live.Components.ChainlinkComponent

  @endpoint DashboardPhoenixWeb.Endpoint

  describe "render/1" do
    test "renders empty state when no issues" do
      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: [],
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      assert html =~ "Chainlink"
      assert html =~ "No open issues"
    end

    test "renders loading state" do
      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: [],
        chainlink_loading: true,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      assert html =~ "Loading issues..."
      assert html =~ "throbber-small"
    end

    test "renders error state" do
      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: [],
        chainlink_loading: false,
        chainlink_error: "Failed to load issues",
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      assert html =~ "Failed to load issues"
    end

    test "renders issues with work button" do
      issues = [
        %{id: 1, title: "Test Issue", status: "open", priority: :high},
        %{id: 2, title: "Another Issue", status: "open", priority: :medium}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      assert html =~ "Test Issue"
      assert html =~ "Another Issue"
      assert html =~ "#1"
      assert html =~ "#2"
      # Work buttons should be present
      assert html =~ "▶"
      assert html =~ "work_on_chainlink"
    end

    test "renders priority badges correctly" do
      issues = [
        %{id: 1, title: "High Priority", status: "open", priority: :high},
        %{id: 2, title: "Medium Priority", status: "open", priority: :medium},
        %{id: 3, title: "Low Priority", status: "open", priority: :low}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      # Priority badges
      assert html =~ "bg-red-500/20"    # high
      assert html =~ "bg-yellow-500/20" # medium
      assert html =~ "bg-blue-500/20"   # low
    end

    test "highlights issue being worked on" do
      issues = [
        %{id: 1, title: "Active Issue", status: "open", priority: :high},
        %{id: 2, title: "Idle Issue", status: "open", priority: :medium}
      ]

      work_in_progress = %{
        1 => %{label: "ticket-123-agent", session_id: "abc"}
      }

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: work_in_progress
      )

      # Should show WIP styling for issue 1
      assert html =~ "bg-accent/10"
      assert html =~ "border-success/50"
      # Should show animated activity indicator
      assert html =~ "status-activity-ring"
      # Should show agent label (formatted from ticket-123-agent)
      assert html =~ "agent"
    end

    test "hides work button for issues being worked on" do
      issues = [
        %{id: 1, title: "Active Issue", status: "open", priority: :high}
      ]

      work_in_progress = %{
        1 => %{label: "ticket-1-worker", session_id: "abc"}
      }

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: work_in_progress
      )

      # Work button should NOT be present for the in-progress issue
      refute html =~ ~r/phx-value-id="1".*▶/s
      # Activity indicator should be present instead
      assert html =~ "status-activity-ring"
    end

    test "shows work button for issues not being worked on" do
      issues = [
        %{id: 1, title: "Active Issue", status: "open", priority: :high},
        %{id: 2, title: "Idle Issue", status: "open", priority: :medium}
      ]

      work_in_progress = %{
        1 => %{label: "agent-123", session_id: "abc"}
      }

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: work_in_progress
      )

      # Work button should be present for issue 2
      assert html =~ ~r/phx-value-id="2"/
    end

    test "renders collapsed state" do
      issues = [
        %{id: 1, title: "Test Issue", status: "open", priority: :high}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: true,
        chainlink_work_in_progress: %{}
      )

      # Header should still be visible
      assert html =~ "Chainlink"
      # Collapsed class should be applied
      assert html =~ "max-h-0"
    end

    test "shows issue count in header" do
      issues = [
        %{id: 1, title: "Issue 1", status: "open", priority: :high},
        %{id: 2, title: "Issue 2", status: "open", priority: :medium},
        %{id: 3, title: "Issue 3", status: "open", priority: :low}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      # Should show count of 3
      assert html =~ ">3<"
    end

    test "renders status icons correctly" do
      issues = [
        %{id: 1, title: "Open Issue", status: "open", priority: :high},
        %{id: 2, title: "Closed Issue", status: "closed", priority: :medium}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      # Open status icon
      assert html =~ "○"
      # Closed status icon
      assert html =~ "●"
    end

    test "shows default Working label when no label provided" do
      issues = [
        %{id: 1, title: "Active Issue", status: "open", priority: :high}
      ]

      work_in_progress = %{
        1 => %{session_id: "abc"}  # No label key
      }

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: work_in_progress
      )

      # Should show default "Working" label
      assert html =~ "Working"
    end
  end
end
