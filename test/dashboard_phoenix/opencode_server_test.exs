defmodule DashboardPhoenix.OpenCodeServerTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.OpenCodeServer

  describe "GenServer behavior - init" do
    test "init returns expected initial state" do
      {:ok, state} = OpenCodeServer.init([])

      assert state.port == 9100  # Default port
      assert state.running == false
      assert state.os_pid == nil
      assert state.port_ref == nil
      assert state.cwd == nil
      assert state.started_at == nil
      assert state.output_buffer == ""
    end

    test "init accepts custom port via opts" do
      {:ok, state} = OpenCodeServer.init(port: 9200)

      assert state.port == 9200
    end
  end

  describe "GenServer behavior - handle_call :status" do
    test "status returns current state info" do
      state = %{
        running: true,
        port: 9100,
        cwd: "/some/path",
        os_pid: 12345,
        started_at: DateTime.utc_now(),
        port_ref: nil,
        output_buffer: ""
      }

      {:reply, status, _new_state} = OpenCodeServer.handle_call(:status, self(), state)

      assert status.running == true
      assert status.port == 9100
      assert status.cwd == "/some/path"
      assert status.pid == 12345
      assert %DateTime{} = status.started_at
    end

    test "status reflects not running state" do
      state = %{
        running: false,
        port: 9100,
        cwd: nil,
        os_pid: nil,
        started_at: nil,
        port_ref: nil,
        output_buffer: ""
      }

      {:reply, status, _} = OpenCodeServer.handle_call(:status, self(), state)

      assert status.running == false
      assert status.cwd == nil
      assert status.pid == nil
    end
  end

  describe "GenServer behavior - handle_call :start_server" do
    test "start_server when already running returns ok with port" do
      state = %{
        running: true,
        port: 9100,
        cwd: "/existing",
        os_pid: 999,
        started_at: DateTime.utc_now(),
        port_ref: nil,
        output_buffer: ""
      }

      {:reply, {:ok, port}, new_state} = 
        OpenCodeServer.handle_call({:start_server, "/new/path"}, self(), state)

      assert port == 9100
      assert new_state.running == true
      assert new_state.cwd == "/existing"  # Not changed
    end
  end

  describe "GenServer behavior - handle_call :stop_server" do
    test "stop_server when not running returns ok" do
      state = %{
        running: false,
        port: 9100,
        cwd: nil,
        os_pid: nil,
        started_at: nil,
        port_ref: nil,
        output_buffer: ""
      }

      {:reply, :ok, new_state} = OpenCodeServer.handle_call(:stop_server, self(), state)

      assert new_state.running == false
    end
  end

  describe "GenServer behavior - handle_info" do
    test "handles port data message" do
      port_ref = make_ref()  # Fake port ref for testing
      state = %{
        running: true,
        port: 9100,
        cwd: "/path",
        os_pid: 123,
        started_at: DateTime.utc_now(),
        port_ref: port_ref,
        output_buffer: ""
      }

      # Note: We can't fully test this without a real port, but we can verify
      # the function exists and handles the pattern
      assert function_exported?(OpenCodeServer, :handle_info, 2)
    end

    test "handles unrecognized messages gracefully" do
      state = %{
        running: false,
        port: 9100,
        cwd: nil,
        os_pid: nil,
        started_at: nil,
        port_ref: nil,
        output_buffer: ""
      }

      {:noreply, new_state} = OpenCodeServer.handle_info(:unknown_message, state)

      assert new_state == state
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
    end
  end

  describe "terminate/2" do
    test "terminate handles cleanup" do
      state = %{
        port_ref: nil,
        os_pid: nil
      }

      # Should not raise
      result = OpenCodeServer.terminate(:normal, state)
      assert result == :ok
    end
  end
end
