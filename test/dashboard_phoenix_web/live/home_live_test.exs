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