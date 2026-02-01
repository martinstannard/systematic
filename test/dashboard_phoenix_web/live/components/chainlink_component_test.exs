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
        chainlink_issues_count: 0,
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
        chainlink_issues_count: 0,
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
        chainlink_issues_count: 0,
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
        chainlink_issues_count: 2,
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
      assert html =~ "show_work_confirm"
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
        chainlink_issues_count: 3,
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
        chainlink_issues_count: 2,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: work_in_progress
      )

      # Should show WIP styling for issue 1
      assert html =~ "bg-success/10"
      assert html =~ "border-r-success/50"
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
        chainlink_issues_count: 1,
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
        chainlink_issues_count: 2,
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
        chainlink_issues_count: 1,
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
        chainlink_issues_count: 3,
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
        chainlink_issues_count: 2,
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
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: work_in_progress
      )

      # Should show default "Working" label
      assert html =~ "Working"
    end
  end

  describe "confirmation modal" do
    test "renders modal when confirm_issue is set" do
      issues = [
        %{id: 42, title: "Test Modal Issue", status: "open", priority: :high}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{},
        confirm_issue: %{id: 42, title: "Test Modal Issue", priority: :high}
      )

      # Modal should be visible
      assert html =~ "Start Work?"
      assert html =~ "#42"
      assert html =~ "Test Modal Issue"
      # Buttons should be present
      assert html =~ "Cancel"
      assert html =~ "confirm_work"
      assert html =~ "cancel_confirm"
    end

    test "does not render modal when confirm_issue is nil" do
      issues = [
        %{id: 1, title: "Test Issue", status: "open", priority: :high}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{},
        confirm_issue: nil
      )

      # Modal should NOT be visible
      refute html =~ "Start Work?"
      refute html =~ "confirm_work"
    end

    test "modal shows correct priority badge" do
      issues = [
        %{id: 99, title: "Low Priority Issue", status: "open", priority: :low}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{},
        confirm_issue: %{id: 99, title: "Low Priority Issue", priority: :low}
      )

      # Should show low priority styling
      assert html =~ "bg-blue-500/20"
      assert html =~ "▼ LOW"
    end
  end

  describe "modal event handling" do
    test "show_work_confirm event sets confirm_issue assign" do
      issues = [
        %{id: 42, title: "Test Issue", status: "open", priority: :high}
      ]

      # Render the component
      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      # Modal should NOT be visible initially
      refute html =~ "Start Work?"
      
      # Work button should be present with correct issue ID
      assert html =~ ~r/phx-click="show_work_confirm"/
      assert html =~ ~r/phx-value-id="42"/
    end

    test "Start Work button in modal has correct phx-click binding" do
      issues = [
        %{id: 42, title: "Test Issue", status: "open", priority: :high}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{},
        confirm_issue: %{id: 42, title: "Test Issue", priority: :high}
      )

      # The Start Work button should have:
      # 1. phx-click="confirm_work"
      # 2. phx-target that points to the component
      assert html =~ ~r/phx-click="confirm_work"/
      assert html =~ ~r/phx-target="-1"/  # -1 is the static representation of @myself
      
      # Verify the button text
      assert html =~ "Start Work"
    end

    test "modal content has noop click handler to prevent backdrop close on content click" do
      issues = [
        %{id: 42, title: "Test Issue", status: "open", priority: :high}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{},
        confirm_issue: %{id: 42, title: "Test Issue", priority: :high}
      )

      # Modal content should have noop handler to prevent clicks from bubbling to backdrop
      # This is critical - without it, clicking buttons inside the modal would also
      # trigger the backdrop's cancel_confirm handler
      assert html =~ ~r/phx-click="noop"/
    end
  end

  describe "event validation" do
    alias DashboardPhoenix.InputValidator

    test "validates chainlink issue IDs correctly" do
      # Valid IDs
      assert {:ok, 1} = InputValidator.validate_chainlink_issue_id("1")
      assert {:ok, 42} = InputValidator.validate_chainlink_issue_id("42")
      assert {:ok, 999} = InputValidator.validate_chainlink_issue_id("999")

      # Invalid IDs
      assert {:error, _} = InputValidator.validate_chainlink_issue_id("0")
      assert {:error, _} = InputValidator.validate_chainlink_issue_id("-1")
      assert {:error, _} = InputValidator.validate_chainlink_issue_id("abc")
      assert {:error, _} = InputValidator.validate_chainlink_issue_id("")
      assert {:error, _} = InputValidator.validate_chainlink_issue_id("1; rm -rf /")
    end

    test "work button has correct phx-click and phx-value attributes" do
      issues = [
        %{id: 42, title: "Test Issue", status: "open", priority: :high}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{}
      )

      # Button should have proper event binding
      assert html =~ ~r/phx-click="show_work_confirm"/
      assert html =~ ~r/phx-value-id="42"/
      assert html =~ ~r/phx-target="-1"/
    end

    test "modal buttons have correct event bindings" do
      issues = [
        %{id: 1, title: "Test Issue", status: "open", priority: :high}
      ]

      html = render_component(ChainlinkComponent,
        id: "test-chainlink",
        chainlink_issues: issues,
        chainlink_issues_count: 1,
        chainlink_loading: false,
        chainlink_error: nil,
        chainlink_collapsed: false,
        chainlink_work_in_progress: %{},
        confirm_issue: %{id: 1, title: "Test Issue", priority: :high}
      )

      # Modal should have confirm and cancel buttons with proper bindings
      assert html =~ ~r/phx-click="confirm_work"/
      assert html =~ ~r/phx-click="cancel_confirm"/
      # Modal should have escape key handler
      assert html =~ ~r/phx-key="Escape"/
    end
  end
end
