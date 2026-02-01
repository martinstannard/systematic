defmodule DashboardPhoenixWeb.Live.Components.PRsComponentTest do
  use DashboardPhoenixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias DashboardPhoenixWeb.Live.Components.PRsComponent

  describe "render/1" do
    test "renders loading state" do
      assigns = %{
        id: "prs-panel",
        github_prs: [],
        github_prs_loading: true,
        github_prs_error: nil,
        github_prs_last_updated: nil,
        prs_collapsed: false,
        prs_in_progress: %{},
        pr_verifications: %{},
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "Pull Requests"
      assert html =~ "Loading PRs..."
      assert html =~ "throbber-small"
    end

    test "renders empty state" do
      assigns = %{
        id: "prs-panel",
        github_prs: [],
        github_prs_loading: false,
        github_prs_error: nil,
        github_prs_last_updated: nil,
        prs_collapsed: false,
        prs_in_progress: %{},
        pr_verifications: %{},
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "Pull Requests"
      assert html =~ "No open PRs"
    end

    test "renders error state" do
      assigns = %{
        id: "prs-panel",
        github_prs: [],
        github_prs_loading: false,
        github_prs_error: "API rate limit exceeded",
        github_prs_last_updated: nil,
        prs_collapsed: false,
        prs_in_progress: %{},
        pr_verifications: %{},
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "API rate limit exceeded"
    end

    test "renders PRs with correct information" do
      pr = %{
        number: 123,
        title: "Add new feature",
        url: "https://github.com/org/repo/pull/123",
        author: "developer",
        branch: "feature/new-feature",
        created_at: DateTime.utc_now() |> DateTime.add(-3600, :second),
        ci_status: :success,
        review_status: :approved,
        has_conflicts: false,
        ticket_ids: ["COR-456"],
        repo: "org/repo"
      }

      assigns = %{
        id: "prs-panel",
        github_prs: [pr],
        github_prs_loading: false,
        github_prs_error: nil,
        github_prs_last_updated: DateTime.utc_now(),
        prs_collapsed: false,
        prs_in_progress: %{},
        pr_verifications: %{},
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "#123"
      assert html =~ "Add new feature"
      assert html =~ "developer"
      assert html =~ "feature/new-feature"
      assert html =~ "Approved"
      assert html =~ "✓ CI"
      assert html =~ "COR-456"
    end

    test "renders CI failure badge with fix button" do
      pr = %{
        number: 456,
        title: "Broken PR",
        url: "https://github.com/org/repo/pull/456",
        author: "developer",
        branch: "feature/broken",
        created_at: DateTime.utc_now(),
        ci_status: :failure,
        review_status: :pending,
        has_conflicts: false,
        ticket_ids: [],
        repo: "org/repo"
      }

      assigns = %{
        id: "prs-panel",
        github_prs: [pr],
        github_prs_loading: false,
        github_prs_error: nil,
        github_prs_last_updated: nil,
        prs_collapsed: false,
        prs_in_progress: %{},
        pr_verifications: %{},
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "✗ CI"
      assert html =~ "Fix"
      assert html =~ "phx-click=\"fix_pr_issues\""
    end

    test "renders conflict badge with fix button" do
      pr = %{
        number: 789,
        title: "Conflicting PR",
        url: "https://github.com/org/repo/pull/789",
        author: "developer",
        branch: "feature/conflict",
        created_at: DateTime.utc_now(),
        ci_status: :success,
        review_status: :pending,
        has_conflicts: true,
        ticket_ids: [],
        repo: "org/repo"
      }

      assigns = %{
        id: "prs-panel",
        github_prs: [pr],
        github_prs_loading: false,
        github_prs_error: nil,
        github_prs_last_updated: nil,
        prs_collapsed: false,
        prs_in_progress: %{},
        pr_verifications: %{},
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "Conflict"
      assert html =~ "Fix"
    end

    test "shows work in progress indicator" do
      pr = %{
        number: 123,
        title: "PR being worked on",
        url: "https://github.com/org/repo/pull/123",
        author: "developer",
        branch: "feature/work",
        created_at: DateTime.utc_now(),
        ci_status: :failure,
        review_status: :pending,
        has_conflicts: false,
        ticket_ids: [],
        repo: "org/repo"
      }

      work_info = %{
        type: :subagent,
        label: "pr-fix-123",
        session_id: "session123",
        status: "running"
      }

      assigns = %{
        id: "prs-panel",
        github_prs: [pr],
        github_prs_loading: false,
        github_prs_error: nil,
        github_prs_last_updated: nil,
        prs_collapsed: false,
        prs_in_progress: %{123 => work_info},
        pr_verifications: %{},
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "pr-fix-123"
      assert html =~ "Working"
    end

    test "shows verification status" do
      pr = %{
        number: 999,
        title: "Verified PR",
        url: "https://github.com/org/repo/pull/999",
        author: "developer",
        branch: "feature/verified",
        created_at: DateTime.utc_now(),
        ci_status: :success,
        review_status: :approved,
        has_conflicts: false,
        ticket_ids: [],
        repo: "org/repo"
      }

      assigns = %{
        id: "prs-panel",
        github_prs: [pr],
        github_prs_loading: false,
        github_prs_error: nil,
        github_prs_last_updated: nil,
        prs_collapsed: false,
        prs_in_progress: %{},
        pr_verifications: %{
          "https://github.com/org/repo/pull/999" => %{
            "verified_by" => "manual",
            "verified_at" => "2025-01-15T10:00:00Z"
          }
        },
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "Verified"
    end

    test "renders collapsed state" do
      assigns = %{
        id: "prs-panel",
        github_prs: [],
        github_prs_loading: false,
        github_prs_error: nil,
        github_prs_last_updated: nil,
        prs_collapsed: true,
        prs_in_progress: %{},
        pr_verifications: %{},
        pr_fix_pending: nil
      }

      html = render_component(PRsComponent, assigns)

      assert html =~ "max-h-0"
      assert html =~ "panel-chevron collapsed"
    end
  end
end
