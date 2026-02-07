defmodule AgentActivityMonitor.SessionParserTest do
  use ExUnit.Case, async: true

  alias AgentActivityMonitor.SessionParser

  describe "parse_jsonl_line/1" do
    test "parses valid JSON" do
      line = ~s|{"type": "session", "id": "abc123"}|
      result = SessionParser.parse_jsonl_line(line)

      assert result == %{"type" => "session", "id" => "abc123"}
    end

    test "returns nil for invalid JSON" do
      assert SessionParser.parse_jsonl_line("not json") == nil
    end

    test "returns nil for empty string" do
      assert SessionParser.parse_jsonl_line("") == nil
    end
  end

  describe "parse_content/3" do
    test "parses session with model and tool calls" do
      content = """
      {"type": "session", "id": "test-123", "cwd": "/home/user/project"}
      {"type": "model_change", "modelId": "claude-opus"}
      {"type": "message", "timestamp": "2024-01-15T10:30:00Z", "message": {"role": "assistant", "content": [{"type": "toolCall", "name": "Read", "arguments": {"path": "/file.ex"}}]}}
      """

      result = SessionParser.parse_content(content, "test.jsonl")

      assert result.id == "openclaw-test-123"
      assert result.session_id == "test-123"
      assert result.type == :openclaw
      assert result.model == "claude-opus"
      assert result.cwd == "/home/user/project"
      assert result.tool_call_count == 1
      assert "/file.ex" in result.files_worked
    end

    test "uses filename as session_id when no session event" do
      content = ~s|{"type": "message", "message": {"role": "user", "content": "hello"}}|
      result = SessionParser.parse_content(content, "my-session.jsonl")

      assert result.session_id == "my-session"
    end

    test "defaults to unknown model when no model_change event" do
      content = ~s|{"type": "session", "id": "test"}|
      result = SessionParser.parse_content(content, "test.jsonl")

      assert result.model == "unknown"
    end
  end

  describe "extract_tool_calls/2" do
    test "extracts tool calls from assistant messages" do
      events = [
        %{
          "type" => "message",
          "timestamp" => "2024-01-15T10:00:00Z",
          "message" => %{
            "role" => "assistant",
            "content" => [
              %{"type" => "toolCall", "name" => "Read", "arguments" => %{"path" => "/a.ex"}},
              %{"type" => "toolCall", "name" => "Write", "arguments" => %{"path" => "/b.ex"}}
            ]
          }
        }
      ]

      result = SessionParser.extract_tool_calls(events)

      assert length(result) == 2
      assert Enum.at(result, 0).name == "Read"
      assert Enum.at(result, 1).name == "Write"
    end

    test "respects max_actions limit" do
      events = [
        %{
          "type" => "message",
          "message" => %{
            "role" => "assistant",
            "content" =>
              Enum.map(1..20, fn i ->
                %{"type" => "toolCall", "name" => "Tool#{i}", "arguments" => %{}}
              end)
          }
        }
      ]

      result = SessionParser.extract_tool_calls(events, 5)

      assert length(result) == 5
    end

    test "ignores non-assistant messages" do
      events = [
        %{
          "type" => "message",
          "message" => %{
            "role" => "user",
            "content" => [%{"type" => "toolCall", "name" => "Read"}]
          }
        }
      ]

      result = SessionParser.extract_tool_calls(events)

      assert result == []
    end
  end

  describe "extract_files_from_tool_call/1" do
    test "extracts path from Read tool" do
      assert SessionParser.extract_files_from_tool_call(%{
               name: "Read",
               arguments: %{"path" => "/file.ex"}
             }) == ["/file.ex"]
    end

    test "extracts file_path alternative" do
      assert SessionParser.extract_files_from_tool_call(%{
               name: "read",
               arguments: %{"file_path" => "/file.ex"}
             }) == ["/file.ex"]
    end

    test "extracts files from exec command" do
      result =
        SessionParser.extract_files_from_tool_call(%{
          name: "exec",
          arguments: %{"command" => "cat ~/file.ex ./test.ts"}
        })

      assert "~/file.ex" in result
      assert "./test.ts" in result
    end

    test "returns empty for unknown tool" do
      assert SessionParser.extract_files_from_tool_call(%{name: "unknown", arguments: %{}}) == []
    end
  end

  describe "determine_status/2" do
    test "returns idle for nil message" do
      assert SessionParser.determine_status(nil, []) == "idle"
    end

    test "returns executing for pending tool calls" do
      message = %{
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "toolCall", "name" => "Read"}]
        }
      }

      assert SessionParser.determine_status(message, [%{}]) == "executing"
    end

    test "returns thinking after tool result" do
      message = %{"message" => %{"role" => "toolResult"}}
      assert SessionParser.determine_status(message, [%{}]) == "thinking"
    end

    test "returns processing for user message" do
      message = %{"message" => %{"role" => "user"}}
      assert SessionParser.determine_status(message, [%{}]) == "processing"
    end
  end

  describe "parse_timestamp/1" do
    test "parses ISO8601 string" do
      result = SessionParser.parse_timestamp("2024-01-15T10:30:00Z")
      assert result.year == 2024
      assert result.month == 1
      assert result.day == 15
    end

    test "parses millisecond Unix timestamp" do
      result = SessionParser.parse_timestamp(1_705_315_800_000)
      assert %DateTime{} = result
    end

    test "returns DateTime unchanged" do
      now = DateTime.utc_now()
      assert SessionParser.parse_timestamp(now) == now
    end

    test "returns current time for nil" do
      result = SessionParser.parse_timestamp(nil)
      assert DateTime.diff(DateTime.utc_now(), result, :second) < 2
    end
  end

  describe "truncate/2" do
    test "returns unchanged if under limit" do
      assert SessionParser.truncate("short", 10) == "short"
    end

    test "truncates with ellipsis" do
      result = SessionParser.truncate("this is too long", 10)
      assert String.length(result) == 10
      assert String.ends_with?(result, "...")
    end

    test "handles non-string" do
      assert SessionParser.truncate(nil, 10) == ""
    end
  end

  describe "parse_file/2" do
    test "parses a session file" do
      # Create a temp file
      content = """
      {"type": "session", "id": "file-test", "cwd": "/tmp"}
      {"type": "model_change", "modelId": "claude-sonnet"}
      """

      path = Path.join(System.tmp_dir!(), "test_session_#{:rand.uniform(100_000)}.jsonl")
      File.write!(path, content)

      {:ok, result} = SessionParser.parse_file(path)

      assert result.session_id == "file-test"
      assert result.model == "claude-sonnet"

      File.rm!(path)
    end

    test "returns error for non-existent file" do
      assert {:error, :enoent} = SessionParser.parse_file("/nonexistent/file.jsonl")
    end
  end
end
