defmodule DashboardPhoenix.SessionBridgeTest do
  use ExUnit.Case, async: false
  alias DashboardPhoenix.SessionBridge

  @progress_file "/tmp/test-agent-progress.jsonl"
  @sessions_file "/tmp/test-agent-sessions.json"

  setup do
    # Use test-specific files to avoid conflicts
    Application.put_env(:dashboard_phoenix, :progress_file, @progress_file)
    Application.put_env(:dashboard_phoenix, :sessions_file, @sessions_file)
    
    # Clean up files
    File.rm(@progress_file)
    File.rm(@sessions_file)
    
    # Start the GenServer
    start_supervised!({SessionBridge, []})
    
    :ok
  end

  describe "file initialization" do
    test "creates progress file on start" do
      assert File.exists?(@progress_file)
    end

    test "creates sessions file with empty structure on start" do
      assert File.exists?(@sessions_file)
      {:ok, content} = File.read(@sessions_file)
      assert content == ~s({"sessions":[]})
    end
  end

  describe "progress polling" do
    test "reads new progress lines and broadcasts them" do
      # Subscribe to PubSub updates
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
      
      # Write a progress line
      progress_line = %{
        ts: System.system_time(:millisecond),
        agent: "test-agent",
        action: "Read",
        target: "/test/file.ex",
        status: "done"
      } |> Jason.encode!()
      
      File.write!(@progress_file, progress_line <> "\n")
      
      # Wait for polling and broadcast
      Process.sleep(600) # Poll interval is 500ms
      
      # Check we received the broadcast
      assert_receive {:progress, [event]}, 1000
      assert event.agent == "test-agent"
      assert event.action == "Read"
      assert event.target == "/test/file.ex"
      assert event.status == "done"
    end

    test "normalizes event data with defaults" do
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
      
      # Write incomplete progress line
      incomplete_line = ~s({"agent": "test"})
      File.write!(@progress_file, incomplete_line <> "\n")
      
      Process.sleep(600)
      
      assert_receive {:progress, [event]}, 1000
      assert event.agent == "test"
      assert event.action == "unknown"
      assert event.target == ""
      assert event.status == "running"
      assert event.output == ""
      assert event.details == ""
      assert is_integer(event.ts)
    end

    test "handles malformed JSON gracefully" do
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
      
      # Write malformed JSON
      File.write!(@progress_file, "{bad json}\n")
      
      Process.sleep(600)
      
      # Should not crash, should not broadcast
      refute_receive {:progress, _}, 100
    end

    test "keeps only last 100 progress events" do
      # Write 105 progress events
      events = for i <- 1..105 do
        %{
          ts: System.system_time(:millisecond),
          agent: "test-agent-#{i}",
          action: "Read",
          target: "/test/file#{i}.ex",
          status: "done"
        } |> Jason.encode!()
      end
      
      content = Enum.join(events, "\n") <> "\n"
      File.write!(@progress_file, content)
      
      Process.sleep(600)
      
      progress = SessionBridge.get_progress()
      assert length(progress) == 100
      # Should keep the last 100
      assert Enum.at(progress, -1).agent == "test-agent-105"
      assert Enum.at(progress, 0).agent == "test-agent-6"
    end
  end

  describe "session polling" do
    test "reads session updates and broadcasts them" do
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
      
      # Write a sessions file
      sessions_data = %{
        "sessions" => [
          %{
            "id" => "test-session-1",
            "label" => "Test Agent",
            "status" => "running",
            "task" => "Testing things",
            "started_at" => System.system_time(:millisecond),
            "agent_type" => "subagent",
            "model" => "claude-sonnet-4",
            "current_action" => "Read",
            "last_output" => "Processing..."
          }
        ]
      } |> Jason.encode!()
      
      File.write!(@sessions_file, sessions_data)
      
      Process.sleep(600)
      
      assert_receive {:sessions, [session]}, 1000
      assert session.id == "test-session-1"
      assert session.label == "Test Agent"
      assert session.status == "running"
      assert session.task == "Testing things"
      assert session.agent_type == "subagent"
      assert session.model == "claude-sonnet-4"
      assert session.current_action == "Read"
      assert session.last_output == "Processing..."
    end

    test "normalizes session data with defaults" do
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
      
      # Write minimal session data
      sessions_data = %{
        "sessions" => [
          %{"id" => "minimal-session"}
        ]
      } |> Jason.encode!()
      
      File.write!(@sessions_file, sessions_data)
      
      Process.sleep(600)
      
      assert_receive {:sessions, [session]}, 1000
      assert session.id == "minimal-session"
      assert session.label == "minimal-session"
      assert session.status == "running"
      assert session.task == ""
      assert session.agent_type == "subagent"
      assert session.model == "claude"
      assert is_nil(session.current_action)
      assert is_nil(session.last_output)
    end

    test "only polls when file modification time changes" do
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
      
      # Write initial sessions file
      sessions_data = %{"sessions" => []} |> Jason.encode!()
      File.write!(@sessions_file, sessions_data)
      
      Process.sleep(600)
      
      # Clear any initial messages
      receive do
        {:sessions, _} -> :ok
      after
        100 -> :ok
      end
      
      # Wait for another poll cycle without changing the file
      Process.sleep(600)
      
      # Should not receive another message
      refute_receive {:sessions, _}, 100
    end

    test "handles malformed sessions JSON gracefully" do
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
      
      # Write malformed JSON
      File.write!(@sessions_file, "{bad json}")
      
      Process.sleep(600)
      
      # Should not crash, should not broadcast
      refute_receive {:sessions, _}, 100
    end
  end

  describe "GenServer API" do
    test "get_sessions returns current sessions" do
      # Write some sessions
      sessions_data = %{
        "sessions" => [
          %{"id" => "session-1", "label" => "Test 1"},
          %{"id" => "session-2", "label" => "Test 2"}
        ]
      } |> Jason.encode!()
      
      File.write!(@sessions_file, sessions_data)
      
      Process.sleep(600)
      
      sessions = SessionBridge.get_sessions()
      assert length(sessions) == 2
      assert Enum.any?(sessions, &(&1.id == "session-1"))
      assert Enum.any?(sessions, &(&1.id == "session-2"))
    end

    test "get_progress returns current progress events" do
      # Write some progress
      events = [
        %{agent: "test-1", action: "Read", status: "done"},
        %{agent: "test-2", action: "Write", status: "running"}
      ]
      
      content = events
      |> Enum.map(&Jason.encode!/1)
      |> Enum.join("\n")
      
      File.write!(@progress_file, content <> "\n")
      
      Process.sleep(600)
      
      progress = SessionBridge.get_progress()
      assert length(progress) == 2
      assert Enum.any?(progress, &(&1.agent == "test-1"))
      assert Enum.any?(progress, &(&1.agent == "test-2"))
    end

    test "subscribe allows receiving PubSub messages" do
      SessionBridge.subscribe()
      
      # Write some progress
      progress_line = %{
        agent: "test-subscribe",
        action: "Think",
        status: "done"
      } |> Jason.encode!()
      
      File.write!(@progress_file, progress_line <> "\n")
      
      Process.sleep(600)
      
      assert_receive {:progress, [event]}, 1000
      assert event.agent == "test-subscribe"
      assert event.action == "Think"
    end
  end

  describe "incremental file reading" do
    test "only reads new content from progress file" do
      # Write initial content
      File.write!(@progress_file, ~s({"agent": "initial"}) <> "\n")
      
      Process.sleep(600) # Let it read initial content
      
      # Write additional content
      File.write!(@progress_file, ~s({"agent": "initial"}) <> "\n" <> ~s({"agent": "new"}) <> "\n", [:append])
      
      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
      
      Process.sleep(600) # Let it read new content
      
      # Should only receive the new event
      assert_receive {:progress, [event]}, 1000
      assert event.agent == "new"
      
      # Verify total progress includes both
      progress = SessionBridge.get_progress()
      assert length(progress) == 2
    end
  end
end