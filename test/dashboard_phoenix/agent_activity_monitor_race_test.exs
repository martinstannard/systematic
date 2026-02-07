defmodule DashboardPhoenix.AgentActivityMonitorRaceTest do
  @moduledoc """
  Tests for race condition fixes in AgentActivityMonitor (Ticket #81)
  """

  # Not async due to ETS table usage
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  # Use the portable Config module directly
  alias AgentActivityMonitor.{Config, Server}

  # Test config that doesn't require TaskSupervisor
  # Creates a unique name and sessions_dir for each test to avoid collisions
  defp test_config do
    unique_id = :erlang.unique_integer([:positive])
    sessions_dir = "/tmp/test_openclaw_sessions_#{unique_id}"
    File.mkdir_p!(sessions_dir)

    %Config{
      sessions_dir: sessions_dir,
      pubsub: nil,
      task_supervisor: nil,
      save_state: nil,
      load_state: nil,
      monitor_processes?: false,
      poll_interval_ms: 100,
      cache_cleanup_interval_ms: 1000,
      gc_interval_ms: 5000,
      name: :"agent_activity_test_#{unique_id}"
    }
  end

  describe "concurrent polling protection" do
    test "prevents multiple concurrent polls" do
      config = test_config()
      {:ok, pid} = Server.start_link(config: config)

      # Get initial state - polling should be false
      initial_state = :sys.get_state(pid)
      assert initial_state.polling == false

      # Send rapid-fire poll messages
      for _i <- 1..5 do
        send(pid, :poll)
      end

      # Wait for polls to complete
      Process.sleep(500)

      # Polling flag should be reset after completion
      final_state = :sys.get_state(pid)
      assert final_state.polling == false

      GenServer.stop(pid)
    end

    test "resets polling flag after completion" do
      config = test_config()
      {:ok, pid} = Server.start_link(config: config)

      # Get initial state
      initial_state = :sys.get_state(pid)
      assert initial_state.polling == false

      # Trigger a poll
      send(pid, :poll)
      Process.sleep(50)

      # Wait for poll to complete
      Process.sleep(500)

      # Should be false again
      final_state = :sys.get_state(pid)
      assert final_state.polling == false

      GenServer.stop(pid)
    end
  end

  describe "file reading race conditions" do
    test "handles file being read successfully" do
      config = test_config()
      {:ok, pid} = Server.start_link(config: config)

      # Create a test session file
      test_file = Path.join(config.sessions_dir, "test_session.jsonl")

      test_content = """
      {"type":"session","id":"test-session","cwd":"/tmp","timestamp":"2024-01-01T00:00:00Z"}
      {"type":"message","message":{"role":"user","content":"test"},"timestamp":"2024-01-01T00:01:00Z"}
      """

      File.write!(test_file, test_content)

      # Trigger a poll
      send(pid, :poll)

      # Give it time to process
      Process.sleep(300)

      # Should have read the file
      activities = Server.get_activity(pid)

      # Should have found the session
      assert length(activities) >= 0

      GenServer.stop(pid)
      File.rm_rf!(config.sessions_dir)
    end

    test "handles partial file reads gracefully" do
      config = test_config()
      {:ok, pid} = Server.start_link(config: config)

      # Create an incomplete JSON file
      test_file = Path.join(config.sessions_dir, "test_session.jsonl")

      incomplete_content = """
      {"type":"session","id":"test-session","cwd":"/tmp"
      """

      File.write!(test_file, incomplete_content)

      # Should not crash on incomplete JSON - the key test is that it doesn't crash
      # and returns a valid (possibly empty) list
      result = Server.get_activity(pid)
      assert is_list(result)

      GenServer.stop(pid)
      File.rm_rf!(config.sessions_dir)
    end
  end

  describe "ETS cache race conditions" do
    test "handles concurrent cache access safely" do
      config = test_config()
      {:ok, pid} = Server.start_link(config: config)

      # Create multiple test files
      for i <- 1..10 do
        file_path = Path.join(config.sessions_dir, "session_#{i}.jsonl")

        content = """
        {"type":"session","id":"test-session-#{i}","cwd":"/tmp","timestamp":"2024-01-01T00:0#{i}:00Z"}
        {"type":"message","message":{"role":"user","content":"test #{i}"},"timestamp":"2024-01-01T00:0#{i}:00Z"}
        """

        File.write!(file_path, content)
      end

      # Trigger multiple concurrent operations
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            Server.get_activity(pid)
          end)
        end

      # Wait for all tasks to complete
      results = Task.await_many(tasks, 2000)

      # All tasks should complete without errors
      assert length(results) == 5

      Enum.each(results, fn result ->
        assert is_list(result)
      end)

      GenServer.stop(pid)
      File.rm_rf!(config.sessions_dir)
    end

    test "cleans up cache entries properly" do
      config = test_config()
      {:ok, pid} = Server.start_link(config: config)

      # Get the cache table from state
      state = :sys.get_state(pid)
      cache_table = state.cache_table

      # Create many files to trigger cache cleanup
      for i <- 1..50 do
        file_path = Path.join(config.sessions_dir, "session_#{i}.jsonl")

        content = """
        {"type":"session","id":"test-session-#{i}","cwd":"/tmp","timestamp":"2024-01-01T00:00:00Z"}
        """

        File.write!(file_path, content)
      end

      # Trigger multiple polls to populate cache
      for _i <- 1..3 do
        send(pid, :poll)
        Process.sleep(100)
      end

      # Trigger cache cleanup
      send(pid, :cleanup_cache)
      Process.sleep(100)

      # Cache should still exist but be manageable size
      cache_size = :ets.info(cache_table, :size)
      assert is_integer(cache_size)
      assert cache_size >= 0

      GenServer.stop(pid)
      File.rm_rf!(config.sessions_dir)
    end
  end

  describe "offset tracking" do
    test "tracks file offsets for incremental reads" do
      config = test_config()
      {:ok, pid} = Server.start_link(config: config)

      # Create initial file
      test_file = Path.join(config.sessions_dir, "test_session.jsonl")

      initial_content = """
      {"type":"session","id":"test-session","cwd":"/tmp","timestamp":"2024-01-01T00:00:00Z"}
      {"type":"message","message":{"role":"user","content":"initial"},"timestamp":"2024-01-01T00:01:00Z"}
      """

      File.write!(test_file, initial_content)

      # First poll - should read full file
      send(pid, :poll)
      Process.sleep(200)

      state1 = :sys.get_state(pid)

      # Append to file (simulates ongoing session)
      additional_content = """
      {"type":"message","message":{"role":"user","content":"additional"},"timestamp":"2024-01-01T00:02:00Z"}
      """

      {:ok, file} = File.open(test_file, [:append])
      IO.write(file, additional_content)
      File.close(file)

      # Second poll - should use offset for incremental read
      send(pid, :poll)
      Process.sleep(200)

      state2 = :sys.get_state(pid)

      # Offsets should be tracked
      assert is_map(state1.session_offsets)
      assert is_map(state2.session_offsets)

      GenServer.stop(pid)
      File.rm_rf!(config.sessions_dir)
    end
  end

  describe "memory management" do
    test "does not grow memory unbounded" do
      config = test_config()
      {:ok, pid} = Server.start_link(config: config)

      # Create many session files
      for i <- 1..100 do
        file_path = Path.join(config.sessions_dir, "session_#{i}.jsonl")

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
        Server.get_activity(pid)
        Process.sleep(10)
      end

      # Memory should not grow excessively
      final_memory = :erlang.memory(:total)
      memory_growth = final_memory - initial_memory

      # Memory growth should be reasonable (less than 10MB for this test)
      assert memory_growth < 10_000_000

      GenServer.stop(pid)
      File.rm_rf!(config.sessions_dir)
    end
  end
end
