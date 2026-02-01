defmodule DashboardPhoenixWeb.Live.Components.LinearComponentTest do
  use DashboardPhoenixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DashboardPhoenixWeb.Live.Components.LinearComponent
  alias DashboardPhoenix.Status

  # Sample test data
  @sample_tickets [
    %{id: "COR-100", title: "Urgent issue", status: "Triage", url: "https://linear.app/fresh-clinics/issue/COR-100"},
    %{id: "COR-101", title: "Feature request", status: "Backlog", url: "https://linear.app/fresh-clinics/issue/COR-101"},
    %{id: "COR-102", title: "Bug fix needed", status: "Todo", url: "https://linear.app/fresh-clinics/issue/COR-102"},
    %{id: "COR-103", title: "Ready for review", status: "In Review", url: "https://linear.app/fresh-clinics/issue/COR-103"},
    %{id: "COR-104", title: "Another review", status: "In Review", url: "https://linear.app/fresh-clinics/issue/COR-104"}
  ]

  describe "smart component - initial state" do
    test "renders with initial loading state" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{}
        })

      # Panel header should be visible
      assert html =~ "Linear"
      assert html =~ "🎫"

      # Filter buttons should show Status values
      assert html =~ "Triage"
      assert html =~ "Backlog"
      assert html =~ "Todo"
      assert html =~ "In Review"
    end

    test "renders collapsed state correctly" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: true,
          tickets_in_progress: %{}
        })

      # Should have collapsed class
      assert html =~ "max-h-0"
      assert html =~ ~s(aria-expanded="false")
    end

    test "renders expanded state by default" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{}
        })

      # Should have expanded class
      assert html =~ "max-h-[400px]"
      assert html =~ ~s(aria-expanded="true")
    end
  end

  describe "smart component - data updates via linear_data" do
    test "updates with ticket data" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{},
          linear_data: %{
            tickets: @sample_tickets,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Should show ticket count
      assert html =~ "5"

      # Should show "In Review" tickets (default filter)
      assert html =~ "COR-103"
      assert html =~ "COR-104"

      # Filter counts should be shown
      assert html =~ "Triage (1)"
      assert html =~ "Backlog (1)"
      assert html =~ "Todo (1)"
      assert html =~ "In Review (2)"
    end

    test "shows error state" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{},
          linear_data: %{
            tickets: [],
            last_updated: nil,
            error: "Failed to fetch tickets"
          }
        })

      assert html =~ "Failed to fetch tickets"
      assert html =~ "text-error"
    end

    test "shows empty state when no tickets match filter" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{},
          linear_data: %{
            tickets: [
              %{id: "COR-100", title: "Triage ticket", status: "Triage", url: "https://example.com"}
            ],
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Default filter is "In Review" so no tickets should match
      assert html =~ "No tickets found"
    end
  end

  describe "smart component - work in progress" do
    test "shows work indicator for tickets in progress" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{
            "COR-103" => %{type: :opencode, session_id: "test-123", status: "running"}
          },
          linear_data: %{
            tickets: @sample_tickets,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Should show work indicator
      assert html =~ "status-activity-ring"
      assert html =~ "bg-success"
    end

    test "shows play button for tickets not in progress" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{},
          linear_data: %{
            tickets: @sample_tickets,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Should show play button
      assert html =~ "▶"
      assert html =~ "work_on_ticket"
    end
  end

  describe "smart component - filter display" do
    test "highlights active filter" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{},
          linear_data: %{
            tickets: @sample_tickets,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # "In Review" is default filter, should be highlighted
      assert html =~ "bg-purple-500/20"
      assert html =~ ~s(aria-pressed="true")
    end

    test "shows counts for all statuses" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{},
          linear_data: %{
            tickets: @sample_tickets,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ "Triage (1)"
      assert html =~ "Backlog (1)"
      assert html =~ "Todo (1)"
      assert html =~ "In Review (2)"
    end
  end

  describe "smart component - ticket rendering" do
    test "renders ticket links correctly" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{},
          linear_data: %{
            tickets: @sample_tickets,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      assert html =~ "COR-103"
      assert html =~ "COR-104"
      assert html =~ ~s(target="_blank")
      assert html =~ "Ready for review"
      assert html =~ "Another review"
    end

    test "limits displayed tickets to 10" do
      many_tickets =
        for i <- 1..15 do
          %{
            id: "COR-#{i}",
            title: "Ticket #{i}",
            status: "In Review",
            url: "https://example.com/#{i}"
          }
        end

      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{},
          linear_data: %{
            tickets: many_tickets,
            last_updated: DateTime.utc_now(),
            error: nil
          }
        })

      # Should show first 10
      for i <- 1..10 do
        assert html =~ "COR-#{i}"
      end

      # Should not show 11+
      refute html =~ "COR-11"
      refute html =~ "COR-15"
    end
  end

  describe "accessibility" do
    test "includes proper ARIA attributes" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{}
        })

      assert html =~ ~s(role="button")
      assert html =~ ~s(aria-label="Toggle Linear tickets panel")
      assert html =~ ~s(aria-controls="linear-panel-content")
      assert html =~ ~s(aria-live="polite")
    end

    test "has accessible filter buttons" do
      html =
        render_component(LinearComponent, %{
          id: :linear,
          collapsed: false,
          tickets_in_progress: %{}
        })

      assert html =~ ~s(aria-pressed="true")
      assert html =~ ~s(aria-pressed="false")
      assert html =~ "Filter tickets by"
    end
  end
end
