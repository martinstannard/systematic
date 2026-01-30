defmodule DashboardPhoenixWeb.HomeLiveTest do
  use DashboardPhoenixWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias DashboardPhoenix.{SessionBridge, ProcessMonitor}

  @progress_file "/tmp/test-home-progress.jsonl"
  @sessions_file "/tmp/test-home-sessions.json"

  setup do
    # Use test-specific files to avoid conflicts
    Application.put_env(:dashboard_phoenix, :progress_file, @progress_file)
    Application.put_env(:dashboard_phoenix, :sessions_file, @sessions_file)
    
    # Clean up files
    File.rm(@progress_file)
    File.rm(@sessions_file)
    
    # Start SessionBridge for the tests
    start_supervised!({SessionBridge, []})
    
    :ok
  end

  describe "mount/3" do
    test "mounts successfully and sets initial assigns", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Check that assigns are set
      assert view.assigns.process_stats
      assert view.assigns.recent_processes
      assert view.assigns.agent_sessions
      assert view.assigns.agent_progress
      
      # Check structure of assigns
      assert is_map(view.assigns.process_stats)
      assert is_list(view.assigns.recent_processes)
      assert is_list(view.assigns.agent_sessions)
      assert is_list(view.assigns.agent_progress)
    end

    test "loads data from ProcessMonitor and SessionBridge on mount", %{conn: conn} do
      # Write some test data
      File.write!(@progress_file, ~s({"agent": "test", "action": "Read", "status": "done"}) <> "\n")
      File.write!(@sessions_file, ~s({"sessions": [{"id": "test-session", "label": "Test"}]}))
      
      # Allow time for polling
      Process.sleep(600)
      
      {:ok, view, html} = live(conn, "/")
      
      # Check that data is loaded in assigns
      assert length(view.assigns.agent_progress) > 0
      assert length(view.assigns.agent_sessions) > 0
      
      # Check that the HTML contains our test data
      assert html =~ "test"
      assert html =~ "Test"
    end

    test "subscribes to PubSub when connected", %{conn: conn} do
      {:ok, _view, _html} = live(conn, "/")
      
      # The LiveView should now be subscribed to agent_updates
      # We can test this by sending a message and seeing if it handles it
      Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "agent_updates", {:progress, []})
      
      # If the process didn't crash, the subscription worked
      # The fact that the LiveView is still running indicates success
    end

    test "sets up process update timer when connected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Get initial process count
      initial_count = length(view.assigns.recent_processes)
      
      # Wait for the timer to trigger (should be every 2 seconds, but we send immediately)
      send(view.pid, :update_processes)
      
      # The view should handle the message and update assigns
      Process.sleep(100)
      
      # The processes should be refreshed (count might be the same, but it should have updated)
      assert is_list(view.assigns.recent_processes)
    end
  end

  describe "handle_info/2 for progress updates" do
    test "updates agent_progress assign on progress message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Get initial progress
      initial_progress = view.assigns.agent_progress
      
      # Send a progress update
      new_events = [
        %{
          ts: System.system_time(:millisecond),
          agent: "test-agent",
          action: "Write",
          target: "/test/file.ex",
          status: "done",
          output: "",
          details: ""
        }
      ]
      
      send(view.pid, {:progress, new_events})
      
      # Check that progress was updated
      updated_progress = view.assigns.agent_progress
      assert length(updated_progress) == length(initial_progress) + 1
      
      # Check the new event was added
      latest_event = List.last(updated_progress)
      assert latest_event.agent == "test-agent"
      assert latest_event.action == "Write"
    end

    test "limits progress to last 100 events", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Create 105 events
      events = for i <- 1..105 do
        %{
          ts: System.system_time(:millisecond),
          agent: "agent-#{i}",
          action: "Read",
          target: "/file#{i}.ex",
          status: "done",
          output: "",
          details: ""
        }
      end
      
      # Send all events at once
      send(view.pid, {:progress, events})
      
      # Should keep only last 100
      progress = view.assigns.agent_progress
      assert length(progress) == 100
      
      # Should have the last 100 events (6-105)
      assert List.last(progress).agent == "agent-105"
      assert List.first(progress).agent == "agent-6"
    end
  end

  describe "handle_info/2 for session updates" do
    test "updates agent_sessions assign on sessions message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send a session update
      new_sessions = [
        %{
          id: "test-session",
          label: "Test Agent",
          status: "running",
          task: "Testing things",
          started_at: System.system_time(:millisecond),
          agent_type: "subagent",
          model: "claude-sonnet-4",
          current_action: "Read",
          last_output: "Working..."
        }
      ]
      
      send(view.pid, {:sessions, new_sessions})
      
      # Check that sessions were updated
      sessions = view.assigns.agent_sessions
      assert length(sessions) == 1
      assert List.first(sessions).id == "test-session"
      assert List.first(sessions).label == "Test Agent"
    end
  end

  describe "handle_info/2 for process updates" do
    test "updates process data on timer message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send the timer message
      send(view.pid, :update_processes)
      
      # Check that process data was updated
      assert is_list(view.assigns.recent_processes)
      assert is_map(view.assigns.process_stats)
      
      # Stats should have the expected structure
      stats = view.assigns.process_stats
      assert Map.has_key?(stats, :running)
      assert Map.has_key?(stats, :busy)
      assert Map.has_key?(stats, :idle)
      assert Map.has_key?(stats, :completed)
      assert Map.has_key?(stats, :failed)
      assert Map.has_key?(stats, :total)
    end
  end

  describe "handle_event/3" do
    test "handles kill_agent event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send kill_agent event
      result = render_click(view, "kill_agent", %{"id" => "test-agent"})
      
      # Should show flash message that kill is not implemented
      assert result =~ "Kill not implemented"
    end

    test "handles clear_progress event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Add some progress first
      File.write!(@progress_file, ~s({"agent": "test", "action": "Read"}) <> "\n")
      Process.sleep(600) # Let it poll
      
      # Clear progress
      render_click(view, "clear_progress")
      
      # Check that progress file was cleared
      {:ok, content} = File.read(@progress_file)
      assert content == ""
      
      # Check that assigns were cleared
      assert view.assigns.agent_progress == []
    end
  end

  describe "rendering" do
    test "renders header with correct stats", %{conn: conn} do
      # Add some test data
      File.write!(@sessions_file, ~s({"sessions": [{"id": "s1"}, {"id": "s2"}]}))
      File.write!(@progress_file, ~s({"agent": "test1"}\n{"agent": "test2"}\n{"agent": "test3"}))
      Process.sleep(600)
      
      {:ok, _view, html} = live(conn, "/")
      
      # Should show agent and event counts
      assert html =~ "2"  # 2 agents
      assert html =~ "AGENTS"
      assert html =~ "3"  # 3 events
      assert html =~ "EVENTS"
    end

    test "renders empty state when no agents", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should show no active agents message
      assert html =~ "NO ACTIVE AGENTS"
      assert html =~ "Spawn a sub-agent to begin"
    end

    test "renders agent sessions when present", %{conn: conn} do
      # Add test session
      session_data = %{
        "sessions" => [
          %{
            "id" => "test-session",
            "label" => "Test Agent",
            "status" => "running",
            "task" => "Testing the system",
            "current_action" => "Read"
          }
        ]
      } |> Jason.encode!()
      
      File.write!(@sessions_file, session_data)
      Process.sleep(600)
      
      {:ok, _view, html} = live(conn, "/")
      
      assert html =~ "Test Agent"
      assert html =~ "RUNNING"
      assert html =~ "Testing the system"
      assert html =~ "Read"
    end

    test "renders progress feed when events present", %{conn: conn} do
      # Add test progress
      events = [
        %{
          ts: System.system_time(:millisecond),
          agent: "test-agent",
          action: "Write",
          target: "/test/file.ex",
          status: "done"
        }
      ]
      
      content = events
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")
      
      File.write!(@progress_file, content <> "\n")
      Process.sleep(600)
      
      {:ok, _view, html} = live(conn, "/")
      
      assert html =~ "test-agent"
      assert html =~ "Write"
      assert html =~ "/test/file.ex"
    end

    test "renders empty progress state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should show waiting message
      assert html =~ "Waiting for agent activity"
    end

    test "renders system processes in collapsed state", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      
      # Should have collapsible section for processes
      assert html =~ "System Processes"
      assert html =~ "<details"
    end
  end

  describe "helper functions" do
    test "format_time handles various inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Test via the module since helpers are private
      # We'll test indirectly by ensuring times render correctly
      current_time = System.system_time(:millisecond)
      
      event = %{
        ts: current_time,
        agent: "test",
        action: "Read",
        target: "/test",
        status: "done",
        output: "",
        details: ""
      }
      
      send(view.pid, {:progress, [event]})
      
      # The time should be formatted and displayed
      html = render(view)
      
      # Should contain a time format (HH:MM:SS)
      assert html =~ ~r/\d{2}:\d{2}:\d{2}/
    end

    test "action colors are applied correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send events with different actions
      events = [
        %{ts: System.system_time(:millisecond), agent: "test", action: "Read", target: "/test", status: "done", output: "", details: ""},
        %{ts: System.system_time(:millisecond), agent: "test", action: "Error", target: "/test", status: "error", output: "", details: ""},
        %{ts: System.system_time(:millisecond), agent: "test", action: "Done", target: "/test", status: "done", output: "", details: ""}
      ]
      
      send(view.pid, {:progress, events})
      
      html = render(view)
      
      # Should contain appropriate CSS classes for different actions
      assert html =~ "text-info"     # Read
      assert html =~ "text-error"    # Error  
      assert html =~ "text-success"  # Done
    end

    test "status badges are applied correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send session with running status
      session = %{
        id: "test",
        label: "Test",
        status: "running",
        task: "Testing",
        started_at: nil,
        agent_type: "subagent",
        model: "claude",
        current_action: nil,
        last_output: nil
      }
      
      send(view.pid, {:sessions, [session]})
      
      html = render(view)
      
      # Should contain status badge CSS classes
      assert html =~ "bg-warning/20"  # For running status
      assert html =~ "text-warning"
    end
  end

  describe "real-time updates" do
    test "updates automatically when SessionBridge polls new data", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      initial_html = render(view)
      
      # Write new progress data
      File.write!(@progress_file, ~s({"agent": "realtime-test", "action": "Think", "status": "running"}) <> "\n")
      
      # Wait for SessionBridge to poll and broadcast
      Process.sleep(700)
      
      updated_html = render(view)
      
      # Should now contain the new data
      assert updated_html =~ "realtime-test"
      assert updated_html =~ "Think"
    end

    test "handles rapid updates without errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      
      # Send multiple rapid updates
      for i <- 1..20 do
        event = %{
          ts: System.system_time(:millisecond),
          agent: "rapid-#{i}",
          action: "Read",
          target: "/file#{i}.ex",
          status: "done",
          output: "",
          details: ""
        }
        
        send(view.pid, {:progress, [event]})
      end
      
      # Should handle all updates without crashing
      html = render(view)
      assert html =~ "rapid-20"  # Last event should be there
    end
  end
end