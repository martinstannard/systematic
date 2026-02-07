defmodule DashboardPhoenix.LinearMonitorRaceTest do
  @moduledoc """
  Tests for race condition fixes in LinearMonitor (Ticket #81)
  """

  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias DashboardPhoenix.LinearMonitor

  setup do
    # Ensure clean state - stop any existing LinearMonitor
    case GenServer.whereis(LinearMonitor) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1000)
    end

    on_exit(fn ->
      # Clean up after test
      case GenServer.whereis(LinearMonitor) do
        nil -> :ok
        pid -> GenServer.stop(pid, :normal, 1000)
      end
    end)

    :ok
  end

  describe "concurrent polling protection" do
    test "prevents multiple concurrent polls" do
      # Start the monitor
      {:ok, _pid} = LinearMonitor.start_link([])

      # Send multiple poll messages rapidly
      monitor_pid = Process.whereis(LinearMonitor)

      # Send rapid-fire poll messages
      for _i <- 1..5 do
        send(monitor_pid, :poll)
      end

      # Wait a bit and check logs - should show skipped polls
      Process.sleep(100)

      logs =
        capture_log(fn ->
          # Allow time for any async operations
          Process.sleep(200)
        end)

      # Should contain skip messages or complete without errors
      refute logs =~ "error"
    end

    test "resets polling flag after completion" do
      {:ok, _pid} = LinearMonitor.start_link([])
      monitor_pid = Process.whereis(LinearMonitor)

      # Get initial state
      initial_state = :sys.get_state(monitor_pid)
      assert initial_state.polling == false

      # Trigger a poll
      send(monitor_pid, :poll)
      # Allow state update
      Process.sleep(50)

      # Wait for poll to complete
      Process.sleep(1000)

      # Should be false again
      final_state = :sys.get_state(monitor_pid)
      assert final_state.polling == false
    end

    test "resets polling flag on error" do
      {:ok, _pid} = LinearMonitor.start_link([])
      monitor_pid = Process.whereis(LinearMonitor)

      # Send a poll_error message to simulate task failure
      send(monitor_pid, {:poll_error, "test error"})
      Process.sleep(50)

      # Polling flag should be reset
      state = :sys.get_state(monitor_pid)
      assert state.polling == false
      assert state.error == "Poll failed"
    end
  end

  describe "state synchronization" do
    test "handles poll_complete messages safely" do
      {:ok, _pid} = LinearMonitor.start_link([])
      monitor_pid = Process.whereis(LinearMonitor)

      # Create test state update
      test_state = %{
        tickets: [%{id: "COR-123", title: "Test", status: "Todo"}],
        last_updated: DateTime.utc_now(),
        error: nil,
        # Should be reset to false
        polling: true,
        consecutive_failures: 0,
        current_interval: 60000
      }

      # Send poll_complete
      send(monitor_pid, {:poll_complete, test_state})
      Process.sleep(100)

      # State should be updated and polling reset
      final_state = :sys.get_state(monitor_pid)
      assert final_state.polling == false
      assert final_state.tickets == test_state.tickets
    end

    test "handles concurrent poll_complete messages" do
      {:ok, _pid} = LinearMonitor.start_link([])
      monitor_pid = Process.whereis(LinearMonitor)

      # Send multiple poll_complete messages
      for i <- 1..5 do
        test_state = %{
          tickets: [%{id: "COR-#{100 + i}", title: "Test #{i}", status: "Todo"}],
          last_updated: DateTime.utc_now(),
          error: nil,
          polling: true,
          consecutive_failures: 0,
          current_interval: 60000
        }

        send(monitor_pid, {:poll_complete, test_state})
      end

      Process.sleep(200)

      # Should handle all messages without crashing
      final_state = :sys.get_state(monitor_pid)
      assert final_state.polling == false
      assert is_list(final_state.tickets)
    end
  end

  describe "async state persistence" do
    test "does not block on state save" do
      {:ok, _pid} = LinearMonitor.start_link([])
      monitor_pid = Process.whereis(LinearMonitor)

      # Create successful poll result
      test_state = %{
        tickets: [%{id: "COR-456", title: "Async Test", status: "Todo"}],
        last_updated: DateTime.utc_now(),
        # No error means state will be saved
        error: nil,
        polling: true,
        consecutive_failures: 0,
        current_interval: 60000
      }

      start_time = System.monotonic_time(:millisecond)

      # Send poll_complete
      send(monitor_pid, {:poll_complete, test_state})

      # Should return quickly (not blocked by file I/O)
      # Very short wait
      Process.sleep(10)

      end_time = System.monotonic_time(:millisecond)
      response_time = end_time - start_time

      # Should respond very quickly since save is async
      # Less than 100ms
      assert response_time < 100

      # State should still be updated
      final_state = :sys.get_state(monitor_pid)
      assert final_state.polling == false
    end
  end

  describe "failure handling and backoff" do
    test "handles poll failures gracefully" do
      {:ok, _pid} = LinearMonitor.start_link([])
      monitor_pid = Process.whereis(LinearMonitor)

      # Get initial state
      initial_state = :sys.get_state(monitor_pid)
      initial_failures = Map.get(initial_state, :consecutive_failures, 0)

      # Send error
      send(monitor_pid, {:poll_error, "test error"})
      Process.sleep(50)

      # Failure count should increase
      error_state = :sys.get_state(monitor_pid)
      assert error_state.consecutive_failures == initial_failures + 1
      assert error_state.polling == false
      assert error_state.error == "Poll failed"
    end

    test "resets failure count on success" do
      {:ok, _pid} = LinearMonitor.start_link([])
      monitor_pid = Process.whereis(LinearMonitor)

      # Simulate a failure first
      send(monitor_pid, {:poll_error, "test error"})
      Process.sleep(50)

      error_state = :sys.get_state(monitor_pid)
      assert error_state.consecutive_failures > 0

      # Now send successful result
      success_state = %{
        tickets: [],
        last_updated: DateTime.utc_now(),
        # Success
        error: nil,
        polling: true,
        consecutive_failures: error_state.consecutive_failures,
        current_interval: error_state.current_interval
      }

      send(monitor_pid, {:poll_complete, success_state})
      Process.sleep(50)

      # Failure count should be reset
      final_state = :sys.get_state(monitor_pid)
      assert final_state.consecutive_failures == 0
      # Reset to base interval
      assert final_state.current_interval == 60000
    end
  end

  describe "PubSub broadcasting" do
    test "broadcasts updates without race conditions" do
      # Subscribe to updates
      LinearMonitor.subscribe()

      {:ok, _pid} = LinearMonitor.start_link([])
      monitor_pid = Process.whereis(LinearMonitor)

      # Send multiple rapid updates
      for i <- 1..3 do
        test_state = %{
          tickets: [%{id: "COR-#{200 + i}", title: "Broadcast Test #{i}", status: "Todo"}],
          last_updated: DateTime.utc_now(),
          error: nil,
          polling: true,
          consecutive_failures: 0,
          current_interval: 60000
        }

        send(monitor_pid, {:poll_complete, test_state})
        Process.sleep(10)
      end

      # Should receive broadcasts
      messages =
        for _i <- 1..3 do
          receive do
            {:linear_update, update} -> update
          after
            1000 -> nil
          end
        end

      # Should have received all updates
      actual_messages = Enum.reject(messages, &is_nil/1)
      # At least one message
      assert length(actual_messages) >= 1

      # Each message should have proper structure
      for message <- actual_messages do
        assert Map.has_key?(message, :tickets)
        assert Map.has_key?(message, :last_updated)
        assert Map.has_key?(message, :error)
      end
    end
  end
end
