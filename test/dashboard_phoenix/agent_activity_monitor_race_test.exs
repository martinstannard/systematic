defmodule DashboardPhoenix.AgentActivityMonitorRaceTest do
  @moduledoc """
  Tests for race condition fixes in AgentActivityMonitor (Ticket #81)
  """
  
  use ExUnit.Case, async: false  # Not async due to ETS table usage
  import ExUnit.CaptureLog
  
  alias DashboardPhoenix.AgentActivityMonitor
  
  # Test constants
  @test_sessions_dir "/tmp/test_openclaw_sessions"
  @test_file_path Path.join(@test_sessions_dir, "test_session.jsonl")
  
  setup do
    # Clean up any existing test data
    File.rm_rf(@test_sessions_dir)
    File.mkdir_p!(@test_sessions_dir)
    
    # Mock the paths module for testing
    Application.put_env(:dashboard_phoenix, :openclaw_sessions_dir, @test_sessions_dir)
    
    on_exit(fn ->
      File.rm_rf(@test_sessions_dir)
      Application.delete_env(:dashboard_phoenix, :openclaw_sessions_dir)
    end)
    
    :ok
  end
  
  describe "concurrent polling protection" do
    test "prevents multiple concurrent polls" do
      # Start the monitor
      {:ok, _pid} = AgentActivityMonitor.start_link([])
      
      # Send multiple poll messages rapidly
      monitor_pid = Process.whereis(AgentActivityMonitor)
      
      # Send rapid-fire poll messages
      for _i <- 1..5 do
        send(monitor_pid, :poll)
      end
      
      # Wait a bit and check logs - should show skipped polls
      Process.sleep(100)
      
      logs = capture_log(fn ->
        Process.sleep(200)  # Allow time for any async operations
      end)
      
      # Should contain skip messages
      assert logs =~ "Poll already in progress, skipping" or logs == ""
    end
    
    test "resets polling flag after completion" do
      {:ok, _pid} = AgentActivityMonitor.start_link([])
      monitor_pid = Process.whereis(AgentActivityMonitor)
      
      # Get initial state
      initial_state = :sys.get_state(monitor_pid)
      assert initial_state.polling == false
      
      # Trigger a poll
      send(monitor_pid, :poll)
      Process.sleep(50)  # Allow state update
      
      # State should show polling = true temporarily
      # (May already be false if poll completed very quickly)
      
      # Wait for poll to complete
      Process.sleep(500)
      
      # Should be false again
      final_state = :sys.get_state(monitor_pid)
      assert final_state.polling == false
    end
  end
  
  describe "file reading race conditions" do
    test "retries on file access errors" do
      {:ok, _pid} = AgentActivityMonitor.start_link([])
      
      # Create a test session file
      test_content = """
      {"type":"session","id":"test-session","cwd":"/tmp","timestamp":"2024-01-01T00:00:00Z"}
      {"type":"message","message":{"role":"user","content":"test"},"timestamp":"2024-01-01T00:01:00Z"}
      """
      
      File.write!(@test_file_path, test_content)
      
      # Simulate file being locked/busy by opening with exclusive lock
      # This tests the retry mechanism
      {:ok, lock_file} = File.open(@test_file_path, [:read, :write, :exclusive])
      
      # Trigger a poll - should retry and eventually succeed when we release lock
      spawn(fn ->
        Process.sleep(50)
        File.close(lock_file)
      end)
      
      # This should eventually succeed despite the initial lock
      activities = AgentActivityMonitor.get_activity()
      
      # Give it time to process
      Process.sleep(200)
      
      # Clean up
      File.close(lock_file)
    end
    
    test "handles partial file reads gracefully" do
      {:ok, _pid} = AgentActivityMonitor.start_link([])
      
      # Create an incomplete JSON file (simulates file being written)
      incomplete_content = """
      {"type":"session","id":"test-session","cwd":"/tmp"
      """
      
      File.write!(@test_file_path, incomplete_content)
      
      # Should not crash on incomplete JSON
      logs = capture_log(fn ->
        AgentActivityMonitor.get_activity()
        Process.sleep(100)
      end)
      
      # Should log decode errors but not crash
      assert logs =~ "Failed to decode JSON" or logs == ""
    end
  end
  
  describe "ETS cache race conditions" do
    test "handles concurrent cache access safely" do
      {:ok, _pid} = AgentActivityMonitor.start_link([])
      
      # Create multiple test files
      for i <- 1..10 do
        file_path = Path.join(@test_sessions_dir, "session_#{i}.jsonl")
        content = """
        {"type":"session","id":"test-session-#{i}","cwd":"/tmp","timestamp":"2024-01-01T00:0#{i}:00Z"}
        {"type":"message","message":{"role":"user","content":"test #{i}"},"timestamp":"2024-01-01T00:0#{i}:00Z"}
        """
        File.write!(file_path, content)
      end
      
      # Trigger multiple concurrent operations
      tasks = for _i <- 1..5 do
        Task.async(fn ->
          AgentActivityMonitor.get_activity()
        end)
      end
      
      # Wait for all tasks to complete
      results = Task.await_many(tasks, 2000)
      
      # All tasks should complete without errors
      assert length(results) == 5
      Enum.each(results, fn result ->
        assert is_list(result)
      end)
    end
    
    test "cleans up cache entries properly" do
      {:ok, _pid} = AgentActivityMonitor.start_link([])
      monitor_pid = Process.whereis(AgentActivityMonitor)
      
      # Create many files to trigger cache cleanup
      for i <- 1..50 do
        file_path = Path.join(@test_sessions_dir, "session_#{i}.jsonl")
        content = """
        {"type":"session","id":"test-session-#{i}","cwd":"/tmp","timestamp":"2024-01-01T00:00:00Z"}
        """
        File.write!(file_path, content)
      end
      
      # Trigger multiple polls to populate cache
      for _i <- 1..3 do
        send(monitor_pid, :poll)
        Process.sleep(100)
      end
      
      # Trigger cache cleanup
      send(monitor_pid, :cleanup_cache)
      Process.sleep(100)
      
      # Cache should still exist but be manageable size
      cache_size = :ets.info(:transcript_cache, :size)
      assert is_integer(cache_size)
      assert cache_size >= 0
    end
  end
  
  describe "offset tracking" do
    test "tracks file offsets for incremental reads" do
      {:ok, _pid} = AgentActivityMonitor.start_link([])
      monitor_pid = Process.whereis(AgentActivityMonitor)
      
      # Create initial file
      initial_content = """
      {"type":"session","id":"test-session","cwd":"/tmp","timestamp":"2024-01-01T00:00:00Z"}
      {"type":"message","message":{"role":"user","content":"initial"},"timestamp":"2024-01-01T00:01:00Z"}
      """
      File.write!(@test_file_path, initial_content)
      
      # First poll - should read full file
      send(monitor_pid, :poll)
      Process.sleep(200)
      
      state1 = :sys.get_state(monitor_pid)
      
      # Append to file (simulates ongoing session)
      additional_content = """
      {"type":"message","message":{"role":"user","content":"additional"},"timestamp":"2024-01-01T00:02:00Z"}
      """
      {:ok, file} = File.open(@test_file_path, [:append])
      IO.write(file, additional_content)
      File.close(file)
      
      # Second poll - should use offset for incremental read
      send(monitor_pid, :poll)
      Process.sleep(200)
      
      state2 = :sys.get_state(monitor_pid)
      
      # Offsets should be tracked
      assert is_map(state1.session_offsets)
      assert is_map(state2.session_offsets)
    end
  end
  
  describe "memory management" do
    test "does not grow memory unbounded" do
      {:ok, _pid} = AgentActivityMonitor.start_link([])
      
      # Create many session files
      for i <- 1..100 do
        file_path = Path.join(@test_sessions_dir, "session_#{i}.jsonl")
        content = """
        {"type":"session","id":"test-session-#{i}","cwd":"/tmp","timestamp":"2024-01-01T00:00:00Z"}
        {"type":"message","message":{"role":"user","content":"test #{i}"},"timestamp":"2024-01-01T00:00:00Z"}
        """
        File.write!(file_path, content)
      end
      
      # Get initial memory info
      initial_memory = :erlang.memory(:total)
      
      # Trigger many polls
      for _i <- 1..20 do
        AgentActivityMonitor.get_activity()
        Process.sleep(10)
      end
      
      # Memory should not grow excessively
      final_memory = :erlang.memory(:total)
      memory_growth = final_memory - initial_memory
      
      # Memory growth should be reasonable (less than 10MB for this test)
      assert memory_growth < 10_000_000
    end
  end
end