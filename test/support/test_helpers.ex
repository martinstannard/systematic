defmodule DashboardPhoenix.TestHelpers do
  @moduledoc """
  Test helpers for setting up mocks and test data.
  """

  import Mox

  alias DashboardPhoenix.Mocks.{
    FileSystemMock,
    SessionBridgeMock,
    OpenCodeClientMock,
    OpenClawClientMock
  }

  @doc """
  Sets up all mocks for a test with default behaviors.
  Call this in test setup to enable proper test isolation.
  Uses `stub` instead of `expect` for functions that may be called multiple times.
  """
  def setup_mocks do
    # Reset rate limiter for test isolation
    DashboardPhoenix.RateLimiter.reset()

    # File system mock setup - use stub for functions called multiple times
    FileSystemMock
    |> stub(:read, fn _path -> {:ok, ""} end)
    |> stub(:write, fn _path, _content -> :ok end)
    |> stub(:write!, fn _path, _content -> :ok end)
    |> stub(:rm, fn _path -> :ok end)
    |> stub(:exists?, fn _path -> false end)
    |> stub(:atomic_write, fn _path, _content -> :ok end)

    # Session bridge mock setup
    SessionBridgeMock
    |> stub(:get_sessions, fn -> [] end)
    |> stub(:get_progress, fn -> [] end)
    |> stub(:subscribe, fn -> :ok end)
    |> stub(:clear_progress, fn -> :ok end)

    # OpenCode client mock setup
    OpenCodeClientMock
    |> stub(:send_task, fn _prompt, _opts -> {:ok, %{session_id: "mock-session-123"}} end)
    |> stub(:health_check, fn -> :ok end)
    |> stub(:list_sessions, fn -> {:ok, []} end)
    |> stub(:list_sessions_formatted, fn -> {:ok, []} end)
    |> stub(:send_message, fn _session_id, _message -> {:ok, :sent} end)
    |> stub(:delete_session, fn _session_id -> :ok end)

    # OpenClaw client mock setup
    OpenClawClientMock
    |> stub(:work_on_ticket, fn _ticket_id, _details, _opts -> {:ok, %{ticket_id: "mock-ticket"}} end)
    |> stub(:send_message, fn _message, _opts -> {:ok, :sent} end)
    |> stub(:spawn_subagent, fn _prompt, _opts -> {:ok, %{job_id: "mock-job-123"}} end)

    :ok
  end

  @doc """
  Creates mock session data for testing.
  """
  def mock_session_data do
    [
      %{
        id: "test-session-1",
        label: "Test Agent",
        status: "running",
        task: "Testing task",
        started_at: nil,
        agent_type: "subagent",
        model: "claude",
        current_action: nil,
        last_output: nil,
        runtime: "0:01:23",
        total_tokens: 1000,
        tokens_in: 800,
        tokens_out: 200,
        cost: 0.05,
        exit_code: nil,
        session_key: "agent:main:subagent:test-session-1"
      }
    ]
  end

  @doc """
  Creates mock progress data for testing.
  """
  def mock_progress_data do
    [
      %{
        ts: System.system_time(:millisecond),
        agent: "test-agent",
        action: "Read",
        target: "/test.ex",
        status: "done",
        output: "",
        details: ""
      }
    ]
  end

  @doc """
  Sets up file system mocks for specific file operations.
  """
  def setup_file_mocks(files \\ %{}) do
    FileSystemMock
    |> expect(:read, length(files), fn path ->
      case Map.get(files, path) do
        nil -> {:error, :enoent}
        content -> {:ok, content}
      end
    end)
    |> expect(:write, fn _path, _content -> :ok end)
    |> expect(:write!, fn _path, _content -> :ok end)
    |> expect(:rm, fn _path -> :ok end)
    |> expect(:exists?, fn path -> Map.has_key?(files, path) end)
    |> expect(:atomic_write, fn _path, _content -> :ok end)

    :ok
  end

  @doc """
  Sets up session bridge mocks with custom data.
  """
  def setup_session_mocks(sessions \\ [], progress \\ []) do
    SessionBridgeMock
    |> expect(:get_sessions, fn -> sessions end)
    |> expect(:get_progress, fn -> progress end)
    |> expect(:subscribe, fn -> :ok end)
    |> expect(:clear_progress, fn -> :ok end)

    :ok
  end
end