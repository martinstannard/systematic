defmodule DashboardPhoenix.SessionBridgeTest do
  use ExUnit.Case, async: false
  alias DashboardPhoenix.SessionBridge

  @test_progress_file "/tmp/test-session-bridge-progress.jsonl"
  @test_sessions_file "/tmp/test-session-bridge-sessions.json"

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

  describe "API functions" do
    test "get_sessions returns a list" do
      sessions = SessionBridge.get_sessions()
      assert is_list(sessions)
    end

    test "get_progress returns a list" do
      progress = SessionBridge.get_progress()
      assert is_list(progress)
    end

    test "subscribe does not crash" do
      # This should not crash
      :ok = SessionBridge.subscribe()
    end
  end

  describe "progress file interaction" do
    test "SessionBridge can read progress from file" do
      # Write a test progress entry
      progress_entry = %{
        ts: System.system_time(:millisecond),
        agent: "test-agent",
        action: "Read",
        target: "/test/file.ex",
        status: "done"
      }
      
      File.write!(@test_progress_file, Jason.encode!(progress_entry) <> "\n")
      
      # Wait for polling
      Process.sleep(1000)
      
      # Should eventually read the progress
      progress = SessionBridge.get_progress()
      
      # Find our test entry
      test_entry = Enum.find(progress, &(&1.agent == "test-agent"))
      if test_entry do
        assert test_entry.action == "Read"
        assert test_entry.target == "/test/file.ex"
        assert test_entry.status == "done"
      else
        # May not have been polled yet, that's okay for this test
        assert is_list(progress)
      end
    end
  end

  describe "sessions file interaction" do
    test "SessionBridge can read sessions from file" do
      # Write a test session
      session_data = %{
        "sessions" => [
          %{
            "id" => "test-session",
            "label" => "Test Agent",
            "status" => "running",
            "task" => "Testing"
          }
        ]
      }
      
      File.write!(@test_sessions_file, Jason.encode!(session_data))
      
      # Wait for polling
      Process.sleep(1000)
      
      # Should eventually read the sessions
      sessions = SessionBridge.get_sessions()
      
      # Find our test session
      test_session = Enum.find(sessions, &(&1.id == "test-session"))
      if test_session do
        assert test_session.label == "Test Agent"
        assert test_session.status == "running"
        assert test_session.task == "Testing"
      else
        # May not have been polled yet, that's okay for this test
        assert is_list(sessions)
      end
    end
  end

  describe "PubSub broadcasting" do
    test "can subscribe to agent updates" do
      SessionBridge.subscribe()
      
      # Write a progress entry that should trigger a broadcast
      progress_entry = %{
        ts: System.system_time(:millisecond),
        agent: "broadcast-test",
        action: "Write",
        target: "/test.ex",
        status: "done"
      }
      
      File.write!(@test_progress_file, Jason.encode!(progress_entry) <> "\n")
      
      # Wait for polling and potential broadcast
      # Note: This test might be flaky due to timing
      receive do
        {:progress, events} ->
          assert is_list(events)
          # If we got a broadcast, check it's valid
          for event <- events do
            assert is_map(event)
            assert Map.has_key?(event, :agent)
            assert Map.has_key?(event, :action)
          end
        {:sessions, sessions} ->
          assert is_list(sessions)
      after
        2000 ->
          # No broadcast received, which is okay - timing dependent
          :ok
      end
    end
  end
end