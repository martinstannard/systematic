defmodule DashboardPhoenix.ResourceTrackerTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.ResourceTracker

  describe "state metrics and memory limits" do
    test "get_state_metrics returns expected structure" do
      # Start the ResourceTracker for this test (or use existing one)
      case start_supervised({ResourceTracker, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      metrics = ResourceTracker.get_state_metrics()

      assert is_map(metrics)
      assert Map.has_key?(metrics, :tracked_processes)
      assert Map.has_key?(metrics, :total_history_points)
      assert Map.has_key?(metrics, :last_sample)
      assert Map.has_key?(metrics, :memory_usage_mb)
      assert Map.has_key?(metrics, :max_tracked_processes)
      assert Map.has_key?(metrics, :max_history_per_process)

      assert is_integer(metrics.tracked_processes)
      assert is_integer(metrics.total_history_points)
      assert is_number(metrics.memory_usage_mb)
      assert metrics.max_tracked_processes == 100
      assert metrics.max_history_per_process == 60
    end

    test "tracked processes respect limits" do
      case start_supervised({ResourceTracker, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Wait a moment for initial sampling
      Process.sleep(100)

      metrics = ResourceTracker.get_state_metrics()

      # Should not exceed our defined limits
      assert metrics.tracked_processes <= 100
    end

    test "history is bounded per process" do
      case start_supervised({ResourceTracker, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Get current state
      current = ResourceTracker.get_current()

      # Each process should have at most 60 history points
      Enum.each(current, fn {_pid, data} ->
        assert length(data.history) <= 60
      end)
    end
  end

  describe "memory cleanup functionality" do
    test "get_history returns properly structured data" do
      case start_supervised({ResourceTracker, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      history = ResourceTracker.get_history()

      assert is_map(history)

      # Each PID maps to a list of {timestamp, cpu, memory} tuples
      Enum.each(history, fn {pid, data_points} ->
        # PIDs can be strings or integers
        assert is_binary(pid) || is_integer(pid)
        assert is_list(data_points)

        Enum.each(data_points, fn {timestamp, cpu, memory} ->
          assert is_integer(timestamp)
          assert is_number(cpu)
          assert is_integer(memory)
        end)
      end)
    end

    test "get_current returns active processes with latest stats" do
      case start_supervised({ResourceTracker, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Wait for at least one sample
      Process.sleep(100)

      current = ResourceTracker.get_current()

      Enum.each(current, fn {pid, data} ->
        # PIDs can be strings or integers
        assert is_binary(pid) || is_integer(pid)
        assert is_map(data)
        assert Map.has_key?(data, :timestamp)
        assert Map.has_key?(data, :cpu)
        assert Map.has_key?(data, :memory)
        assert Map.has_key?(data, :history)
      end)
    end

    test "cleanup constants are reasonable" do
      # Test that cleanup thresholds make sense
      case start_supervised({ResourceTracker, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      metrics = ResourceTracker.get_state_metrics()

      # Max processes should be reasonable (100)
      assert metrics.max_tracked_processes == 100

      # History per process should be reasonable (60 = 5 minutes at 5s intervals)
      assert metrics.max_history_per_process == 60
    end
  end

  describe "telemetry and monitoring" do
    test "total history points calculation" do
      case start_supervised({ResourceTracker, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      metrics = ResourceTracker.get_state_metrics()

      # Total history points should be the sum of all process histories
      assert is_integer(metrics.total_history_points)
      assert metrics.total_history_points >= 0

      # Should not exceed max_processes * max_history_per_process
      max_possible = metrics.max_tracked_processes * metrics.max_history_per_process
      assert metrics.total_history_points <= max_possible
    end

    test "memory usage is reported" do
      case start_supervised({ResourceTracker, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      metrics = ResourceTracker.get_state_metrics()

      assert is_number(metrics.memory_usage_mb)
      assert metrics.memory_usage_mb > 0
    end
  end
end
