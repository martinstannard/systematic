defmodule DashboardPhoenix.GeminiServerTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.GeminiServer

  describe "GenServer behavior - init" do
    test "init returns expected initial state" do
      {:ok, state} = GeminiServer.init([])

      assert state.running == false
      assert state.cwd != nil  # Uses default cwd
      assert state.started_at == nil
      assert state.busy == false
      assert state.gemini_path == nil
    end

    test "init accepts custom cwd via opts" do
      {:ok, state} = GeminiServer.init(cwd: "/custom/path")

      assert state.cwd == "/custom/path"
    end
  end

  describe "GenServer behavior - handle_call :status" do
    test "status returns current state info" do
      state = %{
        running: true,
        cwd: "/work/dir",
        started_at: DateTime.utc_now(),
        busy: false,
        gemini_path: "/usr/local/bin/gemini"
      }

      {:reply, status, _new_state} = GeminiServer.handle_call(:status, self(), state)

      assert status.running == true
      assert status.cwd == "/work/dir"
      assert status.busy == false
      assert %DateTime{} = status.started_at
    end

    test "status reflects busy state" do
      state = %{
        running: true,
        cwd: "/work/dir",
        started_at: DateTime.utc_now(),
        busy: true,
        gemini_path: "/usr/local/bin/gemini"
      }

      {:reply, status, _} = GeminiServer.handle_call(:status, self(), state)

      assert status.busy == true
    end
  end

  describe "GenServer behavior - handle_call :start_server" do
    test "start_server when already running returns :already_running" do
      state = %{
        running: true,
        cwd: "/existing",
        started_at: DateTime.utc_now(),
        busy: false,
        gemini_path: "/path/to/gemini"
      }

      {:reply, {:ok, :already_running}, new_state} = 
        GeminiServer.handle_call({:start_server, "/new/path"}, self(), state)

      assert new_state.running == true
      assert new_state.cwd == "/existing"  # Not changed
    end
  end

  describe "GenServer behavior - handle_call :stop_server" do
    test "stop_server disables the server" do
      state = %{
        running: true,
        cwd: "/work/dir",
        started_at: DateTime.utc_now(),
        busy: false,
        gemini_path: "/path/to/gemini"
      }

      {:reply, :ok, new_state} = GeminiServer.handle_call(:stop_server, self(), state)

      assert new_state.running == false
      assert new_state.started_at == nil
    end
  end

  describe "GenServer behavior - handle_call :send_prompt" do
    test "send_prompt when not running returns error" do
      state = %{
        running: false,
        cwd: "/work/dir",
        started_at: nil,
        busy: false,
        gemini_path: nil
      }

      {:reply, {:error, :not_running}, new_state} = 
        GeminiServer.handle_call({:send_prompt, "hello"}, self(), state)

      assert new_state == state
    end

    test "send_prompt when busy returns error" do
      state = %{
        running: true,
        cwd: "/work/dir",
        started_at: DateTime.utc_now(),
        busy: true,
        gemini_path: "/path/to/gemini"
      }

      {:reply, {:error, :busy}, new_state} = 
        GeminiServer.handle_call({:send_prompt, "hello"}, self(), state)

      assert new_state == state
    end

    test "send_prompt when available sets busy and starts async task" do
      state = %{
        running: true,
        cwd: "/work/dir",
        started_at: DateTime.utc_now(),
        busy: false,
        gemini_path: "/path/to/gemini"
      }

      {:reply, :ok, new_state} = 
        GeminiServer.handle_call({:send_prompt, "test prompt"}, self(), state)

      assert new_state.busy == true
    end
  end

  describe "GenServer behavior - handle_info :prompt_complete" do
    test "prompt_complete success clears busy flag" do
      state = %{
        running: true,
        cwd: "/work/dir",
        started_at: DateTime.utc_now(),
        busy: true,
        gemini_path: "/path/to/gemini"
      }

      {:noreply, new_state} = 
        GeminiServer.handle_info({:prompt_complete, {:ok, "response text"}}, state)

      assert new_state.busy == false
    end

    test "prompt_complete error clears busy flag" do
      state = %{
        running: true,
        cwd: "/work/dir",
        started_at: DateTime.utc_now(),
        busy: true,
        gemini_path: "/path/to/gemini"
      }

      {:noreply, new_state} = 
        GeminiServer.handle_info({:prompt_complete, {:error, "some error"}}, state)

      assert new_state.busy == false
    end
  end

  describe "GenServer behavior - handle_info unknown" do
    test "handles unrecognized messages gracefully" do
      state = %{
        running: false,
        cwd: "/work/dir",
        started_at: nil,
        busy: false,
        gemini_path: nil
      }

      {:noreply, new_state} = GeminiServer.handle_info(:unknown_message, state)

      assert new_state == state
    end
  end

  describe "module exports" do
    test "exports expected client API functions" do
      assert function_exported?(GeminiServer, :start_link, 1)
      assert function_exported?(GeminiServer, :start_server, 0)
      assert function_exported?(GeminiServer, :start_server, 1)
      assert function_exported?(GeminiServer, :stop_server, 0)
      assert function_exported?(GeminiServer, :status, 0)
      assert function_exported?(GeminiServer, :running?, 0)
      assert function_exported?(GeminiServer, :send_prompt, 1)
      assert function_exported?(GeminiServer, :subscribe, 0)
    end
  end
end
