defmodule DashboardPhoenix.ChainlinkWorkTrackerTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.ChainlinkWorkTracker

  @moduletag :chainlink_tracker

  setup do
    # Clean up any existing persistence file before each test
    data_dir = Application.get_env(:dashboard_phoenix, :data_dir, "priv/data")
    path = Path.join(data_dir, "chainlink_work_progress.json")
    File.rm(path)
    
    # Start the tracker if not already running
    case GenServer.whereis(ChainlinkWorkTracker) do
      nil ->
        {:ok, _pid} = ChainlinkWorkTracker.start_link([])
      _pid ->
        # Clear existing state by completing all work
        for {id, _} <- ChainlinkWorkTracker.get_all_work() do
          ChainlinkWorkTracker.complete_work(id)
        end
    end
    
    :ok
  end

  describe "start_work/2" do
    test "records work for an issue" do
      work_info = %{label: "test-agent", job_id: "job-123", type: :subagent}
      
      assert :ok = ChainlinkWorkTracker.start_work(42, work_info)
      
      all_work = ChainlinkWorkTracker.get_all_work()
      assert Map.has_key?(all_work, 42)
      assert all_work[42].label == "test-agent"
      assert all_work[42].job_id == "job-123"
      assert Map.has_key?(all_work[42], :started_at)
    end
  end

  describe "complete_work/1" do
    test "removes work for an issue" do
      work_info = %{label: "test-agent"}
      ChainlinkWorkTracker.start_work(42, work_info)
      
      assert :ok = ChainlinkWorkTracker.complete_work(42)
      
      all_work = ChainlinkWorkTracker.get_all_work()
      refute Map.has_key?(all_work, 42)
    end
  end

  describe "has_work?/1" do
    test "returns true for issues with work" do
      work_info = %{label: "test-agent"}
      ChainlinkWorkTracker.start_work(42, work_info)
      
      assert ChainlinkWorkTracker.has_work?(42)
    end

    test "returns false for issues without work" do
      refute ChainlinkWorkTracker.has_work?(999)
    end
  end

  describe "sync_with_sessions/1" do
    test "removes entries for sessions no longer running" do
      # Add work with a session ID
      work_info = %{label: "test-agent", session_id: "session-abc"}
      ChainlinkWorkTracker.start_work(42, work_info)
      
      # Add work without session ID (should be kept)
      work_info_manual = %{label: "manual-work"}
      ChainlinkWorkTracker.start_work(43, work_info_manual)
      
      # Sync with empty session list (simulating no active sessions)
      ChainlinkWorkTracker.sync_with_sessions([])
      
      # Give it a moment to process
      Process.sleep(50)
      
      all_work = ChainlinkWorkTracker.get_all_work()
      
      # Issue 42 should be removed (session not in active list)
      refute Map.has_key?(all_work, 42)
      # Issue 43 should remain (no session_id)
      assert Map.has_key?(all_work, 43)
    end

    test "keeps entries for active sessions" do
      work_info = %{label: "test-agent", session_id: "session-abc"}
      ChainlinkWorkTracker.start_work(42, work_info)
      
      # Sync with session still active
      ChainlinkWorkTracker.sync_with_sessions(["session-abc"])
      
      Process.sleep(50)
      
      assert ChainlinkWorkTracker.has_work?(42)
    end
  end

  describe "persistence" do
    test "work survives tracker restart" do
      work_info = %{label: "persistent-agent", job_id: "job-456"}
      ChainlinkWorkTracker.start_work(99, work_info)
      
      # Stop the tracker
      GenServer.stop(ChainlinkWorkTracker)
      
      # Restart it
      {:ok, _pid} = ChainlinkWorkTracker.start_link([])
      
      # Work should still be there
      assert ChainlinkWorkTracker.has_work?(99)
      all_work = ChainlinkWorkTracker.get_all_work()
      assert all_work[99].label == "persistent-agent"
    end
  end
end
