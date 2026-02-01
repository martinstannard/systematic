defmodule DashboardPhoenixWeb.Live.Components.ChainlinkComponentTest do
  use DashboardPhoenixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DashboardPhoenixWeb.Live.Components.ChainlinkComponent

  @endpoint DashboardPhoenixWeb.Endpoint

  # Sample test data
  @sample_issues [
    %{id: 1, title: "High Priority Issue", status: "open", priority: :high},
    %{id: 2, title: "Medium Priority Issue", status: "open", priority: :medium},
    %{id: 3, title: "Low Priority Issue", status: "open", priority: :low},
    %{id: 4, title: "Closed Issue", status: "closed", priority: :medium}
  ]

  describe "smart component - initial state" do
    test "renders with initial loading state" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{}
        })

      # Panel header should be visible
      assert html =~ "Chainlink"
      assert html =~ "🔗"

      # Should show loading indicator while fetching initial data
      # (if monitor returns empty, will show "No open issues")
    end

    test "renders collapsed state correctly" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: true,
          work_in_progress: %{}
        })

      # Should have collapsed class
      assert html =~ "max-h-0"
      assert html =~ ~s(aria-expanded="false")
    end

    test "renders expanded state by default" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{}
        })

      # Should have expanded class
      assert html =~ "max-h-[400px]"
      assert html =~ ~s(aria-expanded="true")
    end
  end

  describe "smart component - data updates via chainlink_data" do
    test "renders empty state when no issues" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: [],
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ "Chainlink"
      assert html =~ "No open issues"
    end

    test "renders error state" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: [],
            last_updated: nil,
            error: "Failed to load issues"
          }
        })

      assert html =~ "Failed to load issues"
    end

    test "renders issues with work button" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ "High Priority Issue"
      assert html =~ "Medium Priority Issue"
      assert html =~ "Low Priority Issue"
      assert html =~ "#1"
      assert html =~ "#2"
      # Work buttons should be present
      assert html =~ "▶"
      assert html =~ "show_work_confirm"
    end

    test "renders priority badges correctly" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Priority badges
      assert html =~ "bg-red-500/20"    # high
      assert html =~ "bg-yellow-500/20" # medium
      assert html =~ "bg-blue-500/20"   # low
    end

    test "highlights issue being worked on" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{1 => %{label: "ticket-1-feature"}},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Should have work-in-progress styling
      assert html =~ "bg-success/10"
      # Should show the agent label
      assert html =~ "feature"
    end

    test "hides work button for issues being worked on" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{1 => %{label: "ticket-1-feature"}},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # The work button should NOT have phx-value-id="1" but should have for others
      # (hard to test exactly, but we can check the activity ring is present)
      assert html =~ "status-activity-ring"
    end

    test "shows work button for issues not being worked on" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Work buttons should be present for all issues
      assert html =~ ~s(phx-value-id="1")
      assert html =~ ~s(phx-value-id="2")
    end

    test "shows issue count in header" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Should show count (4 issues)
      assert html =~ ">4<"
    end

    test "renders status icons correctly" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Status icons
      assert html =~ "○" # open
      assert html =~ "●" # closed (the closed issue)
    end

    test "shows default Working label when no label provided" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{1 => %{}},  # No label
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ "Working"
    end
  end

  describe "confirmation modal" do
    test "does not render modal when confirm_issue is nil" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Modal should not be visible by default
      refute html =~ "Start Work?"
      refute html =~ ~s(role="dialog")
    end

    # Note: Testing modal visibility requires LiveView interaction
    # which is harder to test in isolation
  end

  describe "event validation" do
    test "work button has correct phx-click and phx-value attributes" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Should have proper event binding
      assert html =~ ~s(phx-click="show_work_confirm")
      assert html =~ ~s(phx-value-id=)
    end

    test "toggle panel has correct event binding" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: [],
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ ~s(phx-click="toggle_panel")
    end

    test "refresh button has correct event binding" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: [],
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ ~s(phx-click="refresh_chainlink")
    end
  end

  describe "accessibility" do
    test "has proper ARIA attributes for panel" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ ~s(aria-expanded="true")
      assert html =~ ~s(aria-controls="chainlink-panel-content")
      assert html =~ ~s(aria-label="Toggle Chainlink issues panel")
    end

    test "work buttons have accessible labels" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ ~s(aria-label="Start work on issue #1")
    end

    test "issue list has aria-live for updates" do
      html =
        render_component(ChainlinkComponent, %{
          id: :chainlink,
          collapsed: false,
          work_in_progress: %{},
          chainlink_data: %{
            issues: @sample_issues,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Issue list should have aria-live for dynamic updates
      assert html =~ ~s(aria-live="polite")
      assert html =~ ~s(aria-label="Chainlink issue list")
    end
  end

  describe "public API" do
    test "subscribe/0 returns :ok" do
      # This just tests the function exists and doesn't crash
      # In a real app, this would subscribe to PubSub
      result = ChainlinkComponent.subscribe()
      assert result == :ok
    end

    test "refresh/0 doesn't crash" do
      # This triggers a refresh of issues
      assert :ok = ChainlinkComponent.refresh()
    end

    test "handle_pubsub/2 returns :skip for non-chainlink messages" do
      # handle_pubsub with a chainlink_update can't be easily tested in isolation
      # because it calls send_update which requires a LiveView context.
      # But we can test that non-chainlink messages return :skip
      socket = %Phoenix.LiveView.Socket{
        assigns: %{live_action: nil}
      }

      result = ChainlinkComponent.handle_pubsub({:other_message, %{}}, socket)
      assert result == :skip

      result = ChainlinkComponent.handle_pubsub({:linear_update, %{}}, socket)
      assert result == :skip
    end
  end
end
