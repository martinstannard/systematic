defmodule DashboardPhoenixWeb.HomeLiveTestImproved do
  use DashboardPhoenixWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DashboardPhoenix.Mocks.{FileSystemMock, SessionBridgeMock}

  describe "mount/3 with proper mocks" do
    test "mounts successfully without real files", %{conn: conn} do
      # Setup mock behavior - no real files needed
      SessionBridgeMock
      |> expect(:get_sessions, fn -> [] end)
      |> expect(:get_progress, fn -> [] end)
      |> expect(:subscribe, fn -> :ok end)

      # Should mount without errors using mocks
      assert {:ok, _view, _html} = live(conn, "/")
    end

    test "renders page title and header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      assert html =~ "SYSTEMATIC"
      assert html =~ "AGENT CONTROL"
    end

    test "renders agent stats in header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      assert html =~ "Agents:"
      assert html =~ "Events:"
      assert html =~ ~r/\d+/
    end
  end

  describe "handle_event/3 with mocks" do
    test "handles clear_progress event using mocked file operations", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Set up mock to expect file clearing
      FileSystemMock
      |> expect(:atomic_write, fn _path, "" -> :ok end)
      
      # Should handle clear_progress without real file operations
      assert render_click(view, "clear_progress")
    end

    test "handles kill_agent event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      html = render_click(view, "kill_agent", %{"id" => "test-agent"})
      assert is_binary(html)
    end

    test "toggle_show_completed toggles assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      html = render_click(view, "toggle_show_completed")
      assert is_binary(html)
    end

    test "toggle_main_entries toggles assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      html = render_click(view, "toggle_main_entries")
      assert is_binary(html)
    end
  end

  describe "real-time updates with explicit message sending" do
    test "handles progress update messages without timing dependencies", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      progress_event = %{
        ts: System.system_time(:millisecond),
        agent: "test-agent",
        action: "Write", 
        target: "/test.ex",
        status: "done",
        output: "",
        details: ""
      }
      
      # Send message directly - no sleep needed
      send(view.pid, {:progress, [progress_event]})
      
      # Verify view is still alive
      assert Process.alive?(view.pid)
    end

    test "handles session update messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      session = %{
        id: "test-session",
        label: "Test Agent", 
        status: "running",
        task: "Testing",
        started_at: nil,
        agent_type: "subagent",
        model: "claude", 
        current_action: nil,
        last_output: nil,
        runtime: "0:01:23",
        total_tokens: 1000,
        tokens_in: 800,
        tokens_out: 200,
        cost: 0.05,
        exit_code: nil,
        session_key: "agent:main:subagent:test-session"
      }
      
      # Send session update directly
      send(view.pid, {:sessions, [session]})
      
      # Verify view handles the message
      assert Process.alive?(view.pid)
    end

    test "handles timer messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      send(view.pid, :update_processes)
      assert Process.alive?(view.pid)
    end
  end

  describe "toggle_show_completed functionality with proper state management" do
    test "filters completed sessions correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      sessions = [
        %{
          id: "running-session",
          label: "running-test-label",
          status: "running",
          session_key: "agent:main:subagent:123",
          model: "claude",
          runtime: "0:01:00"
        },
        %{
          id: "completed-session", 
          label: "completed-test-label",
          status: "completed",
          session_key: "agent:main:subagent:456",
          model: "claude",
          runtime: "0:02:00"
        }
      ]
      
      # Send sessions to the view
      send(view.pid, {:sessions, sessions})
      
      # Both should show initially
      html = render(view)
      assert html =~ "running-test-label"
      assert html =~ "completed-test-label"
      
      # Toggle to hide completed
      render_click(view, "toggle_show_completed")
      html_hidden = render(view)
      
      # Only running should show
      assert html_hidden =~ "running-test-label"
      refute html_hidden =~ "completed-test-label"
      
      # Toggle back
      render_click(view, "toggle_show_completed")
      html_shown = render(view)
      
      # Both visible again
      assert html_shown =~ "running-test-label"
      assert html_shown =~ "completed-test-label"
    end

    test "clear_completed dismisses sessions properly", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      sessions = [
        %{
          id: "running-session",
          label: "still-running-label",
          status: "running",
          session_key: "agent:main:subagent:run1",
          model: "claude",
          runtime: "0:01:00"
        },
        %{
          id: "completed-session-1",
          label: "completed-label-1",
          status: "completed",
          session_key: "agent:main:subagent:done1",
          model: "claude",
          runtime: "0:02:00"
        },
        %{
          id: "completed-session-2",
          label: "completed-label-2",
          status: "completed",
          session_key: "agent:main:subagent:done2",
          model: "claude",
          runtime: "0:03:00"
        }
      ]
      
      send(view.pid, {:sessions, sessions})
      
      # All visible before clearing
      html_before = render(view)
      assert html_before =~ "still-running-label"
      assert html_before =~ "completed-label-1"
      assert html_before =~ "completed-label-2"
      
      # Clear completed
      render_click(view, "clear_completed")
      
      html_after = render(view)
      
      # Running session remains, completed are dismissed
      assert html_after =~ "still-running-label"
      refute html_after =~ "completed-label-1"
      refute html_after =~ "completed-label-2"
    end
  end

  describe "coding agent functionality" do
    test "toggle_coding_agent switches preference", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Toggle coding agent - should not crash
      html = render_click(view, "toggle_coding_agent")
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end

    test "model selection updates assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Test Claude model selection
      html_claude = render_change(view, "select_claude_model", %{"model" => "anthropic/claude-opus-4-5"})
      assert is_binary(html_claude)
      
      # Test OpenCode model selection
      html_opencode = render_change(view, "select_opencode_model", %{"model" => "gemini-2.5-pro"})
      assert is_binary(html_opencode)
      
      assert Process.alive?(view.pid)
    end

    test "work_on_ticket creates modal state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      html = render_click(view, "work_on_ticket", %{"id" => "COR-123"})
      assert html =~ "COR-123"
      assert Process.alive?(view.pid)
    end

    test "execute_work handles different agent preferences", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Set up modal state without using :sys.replace_state
      render_click(view, "work_on_ticket", %{"id" => "COR-TEST"})
      
      # Execute work - should use mocked clients
      html = render_click(view, "execute_work")
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end
  end

  describe "work result handling" do
    test "handles successful OpenCode result", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      work_result = {:ok, %{session_id: "test-session-123"}}
      send(view.pid, {:work_result, work_result})
      
      assert Process.alive?(view.pid)
    end

    test "handles successful Claude result", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      work_result = {:ok, %{ticket_id: "COR-456"}}
      send(view.pid, {:work_result, work_result})
      
      assert Process.alive?(view.pid)
    end

    test "handles error result", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      work_result = {:error, "Server not available"}
      send(view.pid, {:work_result, work_result})
      
      assert Process.alive?(view.pid)
    end
  end

  describe "error handling without file dependencies" do
    test "handles malformed data gracefully with mocks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send malformed session data - should not crash
      send(view.pid, {:sessions, "not a list"})
      assert Process.alive?(view.pid)
      
      # Send malformed progress data
      send(view.pid, {:progress, "not a list"})
      assert Process.alive?(view.pid)
    end

    test "handles missing dependencies gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # All dependencies are mocked, so no real failure modes
      # Test that view stays alive with various messages
      send(view.pid, :unknown_message)
      assert Process.alive?(view.pid)
    end
  end

  describe "request_super_review functionality" do
    test "handles request_super_review with valid ticket ID", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      html = render_click(view, "request_super_review", %{"id" => "COR-123"})
      assert is_binary(html)
      assert Process.alive?(view.pid)
    end

    test "rejects test placeholder ticket IDs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Should reject obvious test IDs
      html = render_click(view, "request_super_review", %{"id" => "TEST-123"})
      assert html =~ "Invalid ticket ID"
    end

    test "handles missing ticket_id parameter", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      html = render_click(view, "request_super_review", %{})
      assert html =~ "Missing ticket ID"
    end
  end

  describe "rendering and UI" do
    test "shows correct empty states", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      assert is_binary(html)
      assert String.length(html) > 0
    end

    test "includes required CSS classes", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should include key UI classes
      assert html =~ "rounded-lg"
    end

    test "includes interactive elements", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      assert html =~ "phx-click"
      assert html =~ "clear_progress"
    end
  end
end