defmodule DashboardPhoenixWeb.Live.Components.BranchesComponentTest do
  use DashboardPhoenixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias DashboardPhoenixWeb.Live.Components.BranchesComponent

  describe "render/1" do
    test "renders loading state" do
      assigns = %{
        id: "branches-panel",
        unmerged_branches: [],
        branches_loading: true,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "Unmerged Branches"
      assert html =~ "Loading branches..."
      assert html =~ "throbber-small"
    end

    test "renders empty state" do
      assigns = %{
        id: "branches-panel",
        unmerged_branches: [],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "Unmerged Branches"
      assert html =~ "No unmerged branches"
    end

    test "renders error state" do
      assigns = %{
        id: "branches-panel",
        unmerged_branches: [],
        branches_loading: false,
        branches_error: "Git command failed",
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "Git command failed"
    end

    test "renders branches with correct information" do
      branch = %{
        name: "feature/new-feature",
        commits_ahead: 5,
        has_worktree: false,
        worktree_path: nil,
        last_commit_message: "Add new functionality",
        last_commit_author: "developer",
        last_commit_date: DateTime.utc_now() |> DateTime.add(-3600, :second)
      }

      assigns = %{
        id: "branches-panel",
        unmerged_branches: [branch],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: DateTime.utc_now(),
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "feature/new-feature"
      assert html =~ "+5"
      assert html =~ "Add new functionality"
      assert html =~ "developer"
      assert html =~ "Merge"
    end

    test "renders branch with worktree indicator" do
      branch = %{
        name: "feature/worktree-branch",
        commits_ahead: 2,
        has_worktree: true,
        worktree_path: "/home/user/worktrees/feature-worktree-branch",
        last_commit_message: "Work in progress",
        last_commit_author: "developer",
        last_commit_date: DateTime.utc_now()
      }

      assigns = %{
        id: "branches-panel",
        unmerged_branches: [branch],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "🌲"
      assert html =~ "/home/user/worktrees/feature-worktree-branch"
    end

    test "renders merge confirmation buttons when merge is pending" do
      branch = %{
        name: "feature/pending-merge",
        commits_ahead: 3,
        has_worktree: false,
        worktree_path: nil,
        last_commit_message: "Ready to merge",
        last_commit_author: "developer",
        last_commit_date: DateTime.utc_now()
      }

      assigns = %{
        id: "branches-panel",
        unmerged_branches: [branch],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: "feature/pending-merge",
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "Merge?"
      assert html =~ "phx-click=\"execute_merge_branch\""
      assert html =~ "phx-click=\"cancel_merge_branch\""
    end

    test "renders delete confirmation buttons when delete is pending" do
      branch = %{
        name: "feature/pending-delete",
        commits_ahead: 1,
        has_worktree: false,
        worktree_path: nil,
        last_commit_message: "To be deleted",
        last_commit_author: "developer",
        last_commit_date: DateTime.utc_now()
      }

      assigns = %{
        id: "branches-panel",
        unmerged_branches: [branch],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: "feature/pending-delete"
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "Delete?"
      assert html =~ "phx-click=\"execute_delete_branch\""
      assert html =~ "phx-click=\"cancel_delete_branch\""
    end

    test "renders collapsed state" do
      assigns = %{
        id: "branches-panel",
        unmerged_branches: [],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: true,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "max-h-0"
      assert html =~ "-rotate-90"
    end

    test "renders expanded state" do
      assigns = %{
        id: "branches-panel",
        unmerged_branches: [],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "max-h-[400px]"
      refute html =~ "-rotate-90"
    end

    test "renders multiple branches" do
      branches = [
        %{
          name: "feature/branch-one",
          commits_ahead: 2,
          has_worktree: false,
          worktree_path: nil,
          last_commit_message: "First branch",
          last_commit_author: "dev1",
          last_commit_date: DateTime.utc_now()
        },
        %{
          name: "feature/branch-two",
          commits_ahead: 5,
          has_worktree: true,
          worktree_path: "/worktrees/two",
          last_commit_message: "Second branch",
          last_commit_author: "dev2",
          last_commit_date: DateTime.utc_now() |> DateTime.add(-7200, :second)
        }
      ]

      assigns = %{
        id: "branches-panel",
        unmerged_branches: branches,
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "feature/branch-one"
      assert html =~ "feature/branch-two"
      assert html =~ "+2"
      assert html =~ "+5"
      assert html =~ "dev1"
      assert html =~ "dev2"
    end

    test "shows branch count when not loading" do
      branches = [
        %{
          name: "branch1",
          commits_ahead: 1,
          has_worktree: false,
          worktree_path: nil,
          last_commit_message: nil,
          last_commit_author: nil,
          last_commit_date: nil
        },
        %{
          name: "branch2",
          commits_ahead: 2,
          has_worktree: false,
          worktree_path: nil,
          last_commit_message: nil,
          last_commit_author: nil,
          last_commit_date: nil
        }
      ]

      assigns = %{
        id: "branches-panel",
        unmerged_branches: branches,
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      # Should show count of 2
      assert html =~ ">2</span>"
    end

    test "shows last updated time" do
      assigns = %{
        id: "branches-panel",
        unmerged_branches: [],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: DateTime.utc_now() |> DateTime.add(-60, :second),
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "Updated"
      assert html =~ "1m ago"
    end

    test "handles nil last_commit fields gracefully" do
      branch = %{
        name: "feature/minimal",
        commits_ahead: 1,
        has_worktree: false,
        worktree_path: nil,
        last_commit_message: nil,
        last_commit_author: nil,
        last_commit_date: nil
      }

      assigns = %{
        id: "branches-panel",
        unmerged_branches: [branch],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "feature/minimal"
      assert html =~ "+1"
    end

    test "renders refresh button" do
      assigns = %{
        id: "branches-panel",
        unmerged_branches: [],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "phx-click=\"refresh_branches\""
      assert html =~ "↻"
    end

    test "renders toggle panel button" do
      assigns = %{
        id: "branches-panel",
        unmerged_branches: [],
        branches_loading: false,
        branches_error: nil,
        branches_last_updated: nil,
        branches_collapsed: false,
        branch_merge_pending: nil,
        branch_delete_pending: nil
      }

      html = render_component(BranchesComponent, assigns)

      assert html =~ "phx-click=\"toggle_panel\""
    end
  end
end
