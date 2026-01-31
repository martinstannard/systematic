defmodule DashboardPhoenixWeb.Live.Components.OpenCodeComponentTest do
  use DashboardPhoenixWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  alias DashboardPhoenixWeb.Live.Components.OpenCodeComponent

  describe "render/1" do
    test "renders server not running state" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: false, port: nil},
        opencode_sessions: [],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "OpenCode"
      assert html =~ "ACP Server not running"
      assert html =~ "Start Server"
      assert html =~ "phx-click=\"start_opencode_server\""
    end

    test "renders server running with no sessions" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "OpenCode"
      assert html =~ "Running on :8080"
      assert html =~ "No active sessions"
      assert html =~ "phx-click=\"stop_opencode_server\""
    end

    test "renders active session with file changes" do
      session = %{
        id: "session-123",
        slug: "feature-branch",
        title: "Working on feature",
        status: "active",
        directory: "/home/user/code/project",
        file_changes: %{files: 3, additions: 45, deletions: 12}
      }

      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [session],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "feature-branch"
      assert html =~ "active"
      assert html =~ "Working on feature"
      assert html =~ "3 files"
      assert html =~ "+45"
      assert html =~ "-12"
      assert html =~ "/home/user/code/project"
      assert html =~ "phx-click=\"close_opencode_session\""
      assert html =~ "phx-click=\"request_opencode_pr\""
    end

    test "renders idle session" do
      session = %{
        id: "session-456",
        slug: "bugfix-branch",
        title: nil,
        status: "idle",
        directory: nil,
        file_changes: %{files: 0, additions: 0, deletions: 0}
      }

      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [session],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "bugfix-branch"
      assert html =~ "idle"
      # Should still have close button
      assert html =~ "phx-click=\"close_opencode_session\""
      # Should have PR button for idle sessions
      assert html =~ "phx-click=\"request_opencode_pr\""
    end

    test "renders subagent session without PR button" do
      session = %{
        id: "session-789",
        slug: "subagent-task",
        title: "Sub-agent work",
        status: "subagent",
        directory: "/tmp/work",
        file_changes: %{files: 0, additions: 0, deletions: 0}
      }

      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [session],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "subagent-task"
      assert html =~ "subagent"
      # Subagent status shouldn't have PR button (not in ["active", "idle"])
      refute html =~ "phx-click=\"request_opencode_pr\""
      # But should still have close button
      assert html =~ "phx-click=\"close_opencode_session\""
    end

    test "renders collapsed state" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [],
        opencode_collapsed: true
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "max-h-0"
      assert html =~ "-rotate-90"
    end

    test "renders expanded state" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "max-h-[400px]"
      refute html =~ "-rotate-90"
    end

    test "renders multiple sessions" do
      sessions = [
        %{
          id: "session-1",
          slug: "feature-a",
          title: "Feature A",
          status: "active",
          directory: "/code/a",
          file_changes: %{files: 2, additions: 20, deletions: 5}
        },
        %{
          id: "session-2",
          slug: "feature-b",
          title: "Feature B",
          status: "idle",
          directory: "/code/b",
          file_changes: %{files: 1, additions: 10, deletions: 0}
        }
      ]

      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: sessions,
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "feature-a"
      assert html =~ "feature-b"
      assert html =~ "Feature A"
      assert html =~ "Feature B"
      assert html =~ "+20"
      assert html =~ "+10"
    end

    test "renders session count when server is running" do
      sessions = [
        %{
          id: "s1",
          slug: "one",
          title: nil,
          status: "active",
          directory: nil,
          file_changes: %{files: 0, additions: 0, deletions: 0}
        },
        %{
          id: "s2",
          slug: "two",
          title: nil,
          status: "idle",
          directory: nil,
          file_changes: %{files: 0, additions: 0, deletions: 0}
        }
      ]

      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: sessions,
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      # Should show count of 2
      assert html =~ ">2</span>"
    end

    test "does not show session count when server not running" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: false, port: nil},
        opencode_sessions: [],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      # Should not show any count when server is not running
      refute html =~ ">0</span>"
    end

    test "renders refresh button when server is running" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "phx-click=\"refresh_opencode_sessions\""
      assert html =~ "↻"
    end

    test "does not render refresh button when server is not running" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: false, port: nil},
        opencode_sessions: [],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      refute html =~ "phx-click=\"refresh_opencode_sessions\""
    end

    test "renders toggle panel button" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: false, port: nil},
        opencode_sessions: [],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "phx-click=\"toggle_panel\""
    end

    test "session without file changes does not show file stats" do
      session = %{
        id: "session-empty",
        slug: "empty-session",
        title: nil,
        status: "idle",
        directory: nil,
        file_changes: %{files: 0, additions: 0, deletions: 0}
      }

      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [session],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "empty-session"
      # Should not show "0 files" when no changes
      refute html =~ "0 files"
    end

    test "session title same as slug is not duplicated" do
      session = %{
        id: "session-dup",
        slug: "same-name",
        title: "same-name",
        status: "active",
        directory: nil,
        file_changes: %{files: 0, additions: 0, deletions: 0}
      }

      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 8080},
        opencode_sessions: [session],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      # When title == slug, the separate title div should NOT be rendered
      # The slug appears in the span text and as title attribute, but the
      # separate title section should not be shown
      refute html =~ ~r/<div class="text-\[10px\] text-base-content\/50 truncate mb-1"[^>]*>.*same-name.*<\/div>/s
    end

    test "renders different port numbers" do
      assigns = %{
        id: "opencode-panel",
        opencode_server_status: %{running: true, port: 9999},
        opencode_sessions: [],
        opencode_collapsed: false
      }

      html = render_component(OpenCodeComponent, assigns)

      assert html =~ "Running on :9999"
    end
  end
end
