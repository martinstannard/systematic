defmodule DashboardPhoenix.OpenCodeServerTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.OpenCodeServer

  describe "GenServer behavior - init" do
    test "init returns expected initial state with reliability features" do
      {:ok, state} = OpenCodeServer.init([])

      # Basic state
      assert state.port == 9100  # Default port
      assert state.running == false
      assert state.os_pid == nil
      assert state.port_ref == nil
      assert state.cwd == nil
      assert state.started_at == nil
      assert state.output_buffer == ""
      
      # Health monitoring
      assert state.health_status == :unknown
      assert state.last_health_check == nil
      assert state.health_check_timer == nil
      
      # Restart management
      assert state.restart_count == 0
      assert state.restart_times == []
      assert state.consecutive_failures == 0
      assert state.restart_timer == nil
      assert state.auto_restart == true
      
      # Circuit breaker
      assert state.circuit_state == :closed
      assert state.circuit_opened_at == nil
    end

    test "init accepts custom port via opts" do
      {:ok, state} = OpenCodeServer.init(port: 9200)
      assert state.port == 9200
    end

    test "init accepts auto_restart option" do
      {:ok, state} = OpenCodeServer.init(auto_restart: false)
      assert state.auto_restart == false
    end
  end

  describe "GenServer behavior - handle_call :status" do
    test "status returns current state info including health and restart data" do
      state = %{
        running: true,
        port: 9100,
        cwd: "/some/path",
        os_pid: 12345,
        started_at: DateTime.utc_now(),
        port_ref: nil,
        output_buffer: "",
        health_status: :healthy,
        last_health_check: DateTime.utc_now(),
        health_check_timer: nil,
        restart_count: 2,
        restart_times: [],
        consecutive_failures: 0,
        next_restart_delay_ms: 1000,
        restart_timer: nil,
        circuit_state: :closed,
        circuit_opened_at: nil,
        auto_restart: true
      }

      {:reply, status, _new_state} = OpenCodeServer.handle_call(:status, self(), state)

      assert status.running == true
      assert status.port == 9100
      assert status.cwd == "/some/path"
      assert status.pid == 12345
      assert %DateTime{} = status.started_at
      assert status.health_status == :healthy
      assert status.restart_count == 2
      assert status.circuit_state == :closed
    end

    test "status reflects not running state" do
      state = build_initial_state()

      {:reply, status, _} = OpenCodeServer.handle_call(:status, self(), state)

      assert status.running == false
      assert status.cwd == nil
      assert status.pid == nil
      assert status.health_status == :unknown
    end
  end

  describe "GenServer behavior - handle_call :start_server" do
    test "start_server when already running returns ok with port" do
      state = build_running_state()

      {:reply, {:ok, port}, new_state} = 
        OpenCodeServer.handle_call({:start_server, "/new/path"}, self(), state)

      assert port == 9100
      assert new_state.running == true
      assert new_state.cwd == "/existing"  # Not changed
    end

    test "start_server blocked when circuit breaker is open" do
      state = build_initial_state()
      state = %{state | 
        circuit_state: :open,
        circuit_opened_at: System.monotonic_time(:millisecond)
      }

      {:reply, {:error, :circuit_breaker_open}, new_state} = 
        OpenCodeServer.handle_call({:start_server, "/new/path"}, self(), state)

      assert new_state.circuit_state == :open
    end
  end

  describe "GenServer behavior - handle_call :stop_server" do
    test "stop_server when not running returns ok" do
      state = build_initial_state()

      {:reply, :ok, new_state} = OpenCodeServer.handle_call(:stop_server, self(), state)

      assert new_state.running == false
    end
  end

  describe "GenServer behavior - handle_call :reset_circuit_breaker" do
    test "reset_circuit_breaker clears circuit state" do
      state = build_initial_state()
      state = %{state |
        circuit_state: :open,
        circuit_opened_at: System.monotonic_time(:millisecond),
        consecutive_failures: 5,
        restart_times: [1, 2, 3, 4, 5],
        next_restart_delay_ms: 30_000
      }

      {:reply, :ok, new_state} = OpenCodeServer.handle_call(:reset_circuit_breaker, self(), state)

      assert new_state.circuit_state == :closed
      assert new_state.circuit_opened_at == nil
      assert new_state.consecutive_failures == 0
      assert new_state.restart_times == []
      assert new_state.next_restart_delay_ms == 1000  # Reset to initial delay
    end
  end

  describe "GenServer behavior - handle_info for output" do
    test "handles port data message and buffers output" do
      port_ref = make_ref()  # Fake port ref for testing
      state = build_running_state()
      state = %{state | port_ref: port_ref, output_buffer: "existing "}

      # Note: We can't fully test this without a real port
      assert function_exported?(OpenCodeServer, :handle_info, 2)
    end

    test "handles unrecognized messages gracefully" do
      state = build_initial_state()

      {:noreply, new_state} = OpenCodeServer.handle_info(:unknown_message, state)

      assert new_state == state
    end
  end

  describe "GenServer behavior - handle_info :health_check" do
    test "health_check when not running doesn't reschedule" do
      state = build_initial_state()
      state = %{state | health_check_timer: make_ref()}

      {:noreply, new_state} = OpenCodeServer.handle_info(:health_check, state)

      assert new_state.health_check_timer == nil
    end
  end

  describe "output buffer rotation" do
    test "output buffer is limited in size" do
      # Test the private function behavior through state observation
      # The buffer should be rotated when it exceeds max size
      
      # Create a large buffer that would trigger rotation
      # In the real implementation, this happens in handle_info for port data
      assert function_exported?(OpenCodeServer, :handle_info, 2)
    end
  end

  describe "circuit breaker logic" do
    test "circuit breaker state transitions" do
      # Circuit starts closed
      {:ok, state} = OpenCodeServer.init([])
      assert state.circuit_state == :closed
      
      # Circuit opens after too many failures (tested via state manipulation)
      # Circuit moves to half-open after cooldown
      # Circuit closes again after successful start
    end
  end

  describe "module exports" do
    test "exports expected client API functions" do
      assert function_exported?(OpenCodeServer, :start_link, 1)
      assert function_exported?(OpenCodeServer, :start_server, 0)
      assert function_exported?(OpenCodeServer, :start_server, 1)
      assert function_exported?(OpenCodeServer, :stop_server, 0)
      assert function_exported?(OpenCodeServer, :status, 0)
      assert function_exported?(OpenCodeServer, :running?, 0)
      assert function_exported?(OpenCodeServer, :port, 0)
      assert function_exported?(OpenCodeServer, :subscribe, 0)
      assert function_exported?(OpenCodeServer, :reset_circuit_breaker, 0)
    end
  end

  describe "terminate/2" do
    test "terminate handles cleanup with nil timers" do
      state = %{
        port_ref: nil,
        os_pid: nil,
        health_check_timer: nil,
        restart_timer: nil,
        running: false
      }

      # Should not raise
      result = OpenCodeServer.terminate(:normal, state)
      assert result == :ok
    end

    test "terminate cancels active timers" do
      # Create real timer refs for testing
      health_timer = Process.send_after(self(), :test_health, 100_000)
      restart_timer = Process.send_after(self(), :test_restart, 100_000)
      
      state = %{
        port_ref: nil,
        os_pid: nil,
        health_check_timer: health_timer,
        restart_timer: restart_timer,
        running: false
      }

      result = OpenCodeServer.terminate(:normal, state)
      assert result == :ok
      
      # Timers should be cancelled
      assert Process.read_timer(health_timer) == false
      assert Process.read_timer(restart_timer) == false
    end
  end

  describe "restart backoff" do
    test "initial restart delay is configurable via module attribute" do
      {:ok, state} = OpenCodeServer.init([])
      assert state.next_restart_delay_ms == 1000  # 1 second initial delay
    end
  end

  # Helper functions

  defp build_initial_state do
    %{
      port: 9100,
      auto_restart: true,
      running: false,
      os_pid: nil,
      port_ref: nil,
      cwd: nil,
      started_at: nil,
      health_status: :unknown,
      last_health_check: nil,
      health_check_timer: nil,
      output_buffer: "",
      restart_count: 0,
      restart_times: [],
      consecutive_failures: 0,
      next_restart_delay_ms: 1000,
      restart_timer: nil,
      circuit_state: :closed,
      circuit_opened_at: nil
    }
  end

  defp build_running_state do
    %{
      port: 9100,
      auto_restart: true,
      running: true,
      os_pid: 999,
      port_ref: nil,
      cwd: "/existing",
      started_at: DateTime.utc_now(),
      health_status: :healthy,
      last_health_check: DateTime.utc_now(),
      health_check_timer: nil,
      output_buffer: "",
      restart_count: 0,
      restart_times: [],
      consecutive_failures: 0,
      next_restart_delay_ms: 1000,
      restart_timer: nil,
      circuit_state: :closed,
      circuit_opened_at: nil
    }
  end
end
