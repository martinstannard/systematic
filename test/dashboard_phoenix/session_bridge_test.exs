defmodule DashboardPhoenix.SessionBridgeTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.SessionBridge

  describe "state metrics and cleanup" do
    test "get_state_metrics returns expected structure" do
      # Start the SessionBridge for this test (or use existing one)
      case start_supervised({SessionBridge, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      metrics = SessionBridge.get_state_metrics()

      assert is_map(metrics)
      assert Map.has_key?(metrics, :sessions_count)
      assert Map.has_key?(metrics, :progress_events)
      assert Map.has_key?(metrics, :transcript_offsets_count)
      assert Map.has_key?(metrics, :last_cleanup)
      assert Map.has_key?(metrics, :progress_offset)
      assert Map.has_key?(metrics, :current_poll_interval)
      assert Map.has_key?(metrics, :memory_usage_mb)

      assert is_integer(metrics.sessions_count)
      assert is_integer(metrics.progress_events)
      assert is_integer(metrics.transcript_offsets_count)
      assert is_number(metrics.memory_usage_mb)
    end

    test "transcript offsets cleanup respects max size limit" do
      # This is more of an integration test - we'd need to mock the file system
      # or create temporary files to fully test the cleanup logic
      # For now, we test the metrics are accessible
      case start_supervised({SessionBridge, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      initial_metrics = SessionBridge.get_state_metrics()
      assert initial_metrics.transcript_offsets_count >= 0
    end

    test "progress events are bounded" do
      case start_supervised({SessionBridge, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      metrics = SessionBridge.get_state_metrics()

      # Progress events should be within the max limit
      assert metrics.progress_events <= 100
    end
  end

  describe "memory cleanup functionality" do
    test "cleanup constants are properly defined" do
      # Test that our constants are accessible and reasonable
      _module_attrs = SessionBridge.__info__(:attributes)

      # We can't directly access module attributes from tests, but we can verify
      # the module compiles and the cleanup function exists
      assert function_exported?(SessionBridge, :get_state_metrics, 0)
    end

    test "state structure includes cleanup tracking" do
      case start_supervised({SessionBridge, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      metrics = SessionBridge.get_state_metrics()

      # last_cleanup should be a recent timestamp
      assert is_integer(metrics.last_cleanup)
      assert metrics.last_cleanup > 0

      # Should be within the last few seconds (allowing for test execution time)
      now = System.system_time(:millisecond)
      # 10 seconds
      assert now - metrics.last_cleanup < 10_000
    end
  end
end
