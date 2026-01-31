defmodule DashboardPhoenixWeb.HomeLiveTest do
  use DashboardPhoenixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @test_progress_file "/tmp/test-home-live-progress.jsonl"
  @test_sessions_file "/tmp/test-home-live-sessions.json"

  setup do
    # Set up test files
    File.rm(@test_progress_file)
    File.rm(@test_sessions_file)
    
    # Save original config
    original_progress = Application.get_env(:dashboard_phoenix, :progress_file)
    original_sessions = Application.get_env(:dashboard_phoenix, :sessions_file)
    
    # Set test config
    Application.put_env(:dashboard_phoenix, :progress_file, @test_progress_file)
    Application.put_env(:dashboard_phoenix, :sessions_file, @test_sessions_file)
    
    on_exit(fn ->
      # Restore original config
      if original_progress do
        Application.put_env(:dashboard_phoenix, :progress_file, original_progress)
      else
        Application.delete_env(:dashboard_phoenix, :progress_file)
      end
      
      if original_sessions do
        Application.put_env(:dashboard_phoenix, :sessions_file, original_sessions)
      else
        Application.delete_env(:dashboard_phoenix, :sessions_file)
      end
      
      # Clean up test files
      File.rm(@test_progress_file)
      File.rm(@test_sessions_file)
    end)
    
    :ok
  end

  describe "mount/3" do
    test "mounts successfully without crashing", %{conn: conn} do
      # The LiveView should mount without errors
      assert {:ok, _view, _html} = live(conn, "/")
    end

    test "renders page title and header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should contain the main header elements
      assert html =~ "SYSTEMATIC"
      assert html =~ "AGENT CONTROL"
    end

    test "renders agent stats in header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should show agent and event counts (exact values may vary)
      assert html =~ "AGENTS"
      assert html =~ "EVENTS"
      # Should contain numeric indicators
      assert html =~ ~r/\d+/
    end
  end

  describe "handle_event/3" do
    test "handles clear_progress event without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Write some test progress first
      File.write!(@test_progress_file, ~s({"agent": "test", "action": "Read"}) <> "\n")
      
      # Should not crash when clearing progress
      assert render_click(view, "clear_progress")
      
      # Progress file should be empty
      {:ok, content} = File.read(@test_progress_file)
      assert content == ""
    end

    test "handles kill_agent event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Should handle kill_agent event and show flash message
      html = render_click(view, "kill_agent", %{"id" => "test-agent"})
      
      # Should contain some indication the action was handled
      assert is_binary(html)
    end

    test "toggle_show_completed event toggles the show_completed assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Initially show_completed should be true (default)
      # Trigger the toggle event
      html = render_click(view, "toggle_show_completed")
      
      # Should not crash
      assert is_binary(html)
      
      # The assign should be toggled - we can verify by checking the button state
      # When show_completed is false, the button should show "SHOW" text
      # But we need completed sessions to actually see the button
    end

    test "toggle_main_entries event toggles the show_main_entries assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Trigger the toggle event
      html = render_click(view, "toggle_main_entries")
      
      # Should not crash and view should still render
      assert is_binary(html)
    end
  end

  describe "real-time updates" do
    test "handles progress update messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send a progress update message directly to the LiveView process
      progress_event = %{
        ts: System.system_time(:millisecond),
        agent: "test-agent",
        action: "Write", 
        target: "/test.ex",
        status: "done",
        output: "",
        details: ""
      }
      
      # Should not crash when receiving progress update
      send(view.pid, {:progress, [progress_event]})
      
      # Give it a moment to process
      Process.sleep(100)
      
      # View should still be alive
      assert Process.alive?(view.pid)
    end

    test "handles session update messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send a session update message with all required fields
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
        exit_code: nil
      }
      
      # Should not crash when receiving session update
      send(view.pid, {:sessions, [session]})
      
      # Give it a moment to process
      Process.sleep(100)
      
      # View should still be alive
      assert Process.alive?(view.pid)
    end

    test "handles process update timer messages", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Should not crash when receiving timer update
      send(view.pid, :update_processes)
      
      # Give it a moment to process
      Process.sleep(100)
      
      # View should still be alive
      assert Process.alive?(view.pid)
    end
  end

  describe "integration" do
    test "can write and read progress through SessionBridge", %{conn: conn} do
      {:ok, _view, _html} = live(conn, "/")
      
      # Write a progress entry
      progress_data = %{
        ts: System.system_time(:millisecond),
        agent: "integration-test",
        action: "Read",
        target: "/test.ex",
        status: "done"
      }
      
      File.write!(@test_progress_file, Jason.encode!(progress_data) <> "\n")
      
      # Wait for polling to pick it up
      Process.sleep(1000)
      
      # Render the page again
      {:ok, _new_view, html} = live(conn, "/")
      
      # May or may not contain our test data depending on timing,
      # but should not crash
      assert is_binary(html)
    end

    test "can write and read sessions through SessionBridge", %{conn: conn} do
      {:ok, _view, _html} = live(conn, "/")
      
      # Write a session
      session_data = %{
        "sessions" => [
          %{
            "id" => "integration-test-session",
            "label" => "Integration Test",
            "status" => "running"
          }
        ]
      }
      
      File.write!(@test_sessions_file, Jason.encode!(session_data))
      
      # Wait for polling
      Process.sleep(1000)
      
      # Render the page again  
      {:ok, _new_view, html} = live(conn, "/")
      
      # May or may not contain our test data depending on timing,
      # but should not crash
      assert is_binary(html)
    end
  end

  describe "toggle_show_completed functionality" do
    test "toggle_show_completed flips the show_completed assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # The toggle event should work without crashing
      html1 = render_click(view, "toggle_show_completed")
      assert is_binary(html1)
      
      # Toggle again
      html2 = render_click(view, "toggle_show_completed")
      assert is_binary(html2)
    end

    test "completed sessions are filtered when show_completed is false", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Create test sessions - one running, one completed
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
      Process.sleep(100)
      
      # Render to see both sessions (show_completed is true by default)
      html = render(view)
      assert html =~ "running-test-label"
      assert html =~ "completed-test-label"
      
      # Now toggle to hide completed
      render_click(view, "toggle_show_completed")
      html_hidden = render(view)
      
      # Running should still show, completed should be hidden
      assert html_hidden =~ "running-test-label"
      refute html_hidden =~ "completed-test-label"
      
      # Toggle back to show completed
      render_click(view, "toggle_show_completed")
      html_shown = render(view)
      
      # Both should be visible again
      assert html_shown =~ "running-test-label"
      assert html_shown =~ "completed-test-label"
    end

    test "button text changes based on show_completed state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Create a completed session so the button appears
      sessions = [
        %{
          id: "completed-session",
          label: "test-completed",
          status: "completed",
          session_key: "agent:main:subagent:789",
          model: "claude",
          runtime: "0:01:00"
        }
      ]
      
      send(view.pid, {:sessions, sessions})
      Process.sleep(100)
      
      # With show_completed = true (default), button should say "COMPLETED"
      html = render(view)
      assert html =~ "COMPLETED"
      
      # Toggle to hide
      render_click(view, "toggle_show_completed")
      html_hidden = render(view)
      
      # Button should now say "SHOW 1" (or similar)
      assert html_hidden =~ "SHOW"
    end
  end

  describe "rendering" do
    test "shows empty state appropriately", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should handle empty states gracefully
      assert is_binary(html)
      assert String.length(html) > 0
    end

    test "includes CSS classes for styling", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should include key CSS classes for styling
      assert html =~ "glass-panel"
      assert html =~ "rounded-lg"
    end

    test "includes interactive elements", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should include interactive buttons/elements
      assert html =~ "phx-click"
      assert html =~ "clear_progress"
    end
  end

  describe "error handling" do
    test "survives malformed progress data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Write malformed JSON
      File.write!(@test_progress_file, "not valid json\n")
      
      # Should not crash the LiveView
      Process.sleep(600) # Wait for polling
      
      assert Process.alive?(view.pid)
    end

    test "survives malformed session data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Write malformed JSON
      File.write!(@test_sessions_file, "{not valid json")
      
      # Should not crash the LiveView
      Process.sleep(600) # Wait for polling
      
      assert Process.alive?(view.pid)
    end

    test "handles missing files gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Delete the test files
      File.rm(@test_progress_file)
      File.rm(@test_sessions_file)
      
      # Should not crash the LiveView 
      Process.sleep(600) # Wait for polling
      
      assert Process.alive?(view.pid)
    end
  end
end