defmodule DashboardPhoenix.AgentActivityMonitor.SessionParserTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.AgentActivityMonitor.SessionParser

  describe "parse_content/3" do
    test "parses empty content" do
      activity = SessionParser.parse_content("", "test.jsonl")
      
      assert activity.id == "openclaw-test"
      assert activity.session_id == "test"
      assert activity.type == :openclaw
      assert activity.model == "unknown"
      assert activity.status == "idle"
      assert activity.tool_call_count == 0
    end

    test "parses session event" do
      content = ~s({"type":"session","id":"abc123","cwd":"/home/user/code"})
      activity = SessionParser.parse_content(content, "test.jsonl")
      
      assert activity.session_id == "abc123"
      assert activity.cwd == "/home/user/code"
    end

    test "parses model change event" do
      content = ~s({"type":"model_change","modelId":"claude-opus-4"})
      activity = SessionParser.parse_content(content, "test.jsonl")
      
      assert activity.model == "claude-opus-4"
    end

    test "extracts tool calls from assistant messages" do
      content = """
      {"type":"message","timestamp":"2024-01-15T10:30:00Z","message":{"role":"assistant","content":[{"type":"toolCall","name":"Read","arguments":{"path":"/test.ex"}}]}}
      """
      activity = SessionParser.parse_content(content, "test.jsonl")
      
      assert activity.tool_call_count == 1
      assert activity.last_action != nil
      assert activity.last_action.action == "Read"
      assert activity.last_action.target == "/test.ex"
    end

    test "extracts files worked from tool calls" do
      content = """
      {"type":"message","timestamp":"2024-01-15T10:30:00Z","message":{"role":"assistant","content":[{"type":"toolCall","name":"Read","arguments":{"path":"/file1.ex"}}]}}
      {"type":"message","timestamp":"2024-01-15T10:31:00Z","message":{"role":"assistant","content":[{"type":"toolCall","name":"Write","arguments":{"path":"/file2.ex"}}]}}
      """
      activity = SessionParser.parse_content(content, "test.jsonl")
      
      assert "/file1.ex" in activity.files_worked
      assert "/file2.ex" in activity.files_worked
    end

    test "respects max_actions option" do
      # Create content with many tool calls
      tool_calls = for i <- 1..20 do
        ~s({"type":"message","timestamp":"2024-01-15T10:#{String.pad_leading("#{i}", 2, "0")}:00Z","message":{"role":"assistant","content":[{"type":"toolCall","name":"Read","arguments":{"path":"/file#{i}.ex"}}]}})
      end
      content = Enum.join(tool_calls, "\n")
      
      activity = SessionParser.parse_content(content, "test.jsonl", max_actions: 5)
      
      assert activity.tool_call_count == 5
      assert length(activity.recent_actions) == 5
    end
  end

  describe "parse_file/2" do
    test "reads and parses a file" do
      # Create a temp file
      path = Path.join(System.tmp_dir!(), "test_session_#{:rand.uniform(100000)}.jsonl")
      File.write!(path, ~s({"type":"session","id":"file-test","cwd":"/tmp"}))
      
      assert {:ok, activity} = SessionParser.parse_file(path)
      assert activity.session_id == "file-test"
      
      File.rm!(path)
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = SessionParser.parse_file("/nonexistent/file.jsonl")
    end
  end

  describe "parse_jsonl_line/1" do
    test "parses valid JSON" do
      assert %{"type" => "test"} = SessionParser.parse_jsonl_line(~s({"type":"test"}))
    end

    test "returns nil for invalid JSON" do
      assert nil == SessionParser.parse_jsonl_line("not json")
    end

    test "returns nil for empty string" do
      assert nil == SessionParser.parse_jsonl_line("")
    end
  end

  describe "extract_files_from_tool_call/1" do
    test "extracts from Read tool" do
      assert ["/test.ex"] = SessionParser.extract_files_from_tool_call(%{name: "Read", arguments: %{"path" => "/test.ex"}})
    end

    test "extracts from Write tool with file_path" do
      assert ["/output.json"] = SessionParser.extract_files_from_tool_call(%{name: "Write", arguments: %{"file_path" => "/output.json"}})
    end

    test "extracts from exec command" do
      files = SessionParser.extract_files_from_tool_call(%{name: "exec", arguments: %{"command" => "cat ~/code/app.ex ./test.exs"}})
      assert "~/code/app.ex" in files
      assert "./test.exs" in files
    end

    test "returns empty for unknown tool" do
      assert [] = SessionParser.extract_files_from_tool_call(%{name: "browser", arguments: %{"action" => "click"}})
    end

    test "returns empty for nil input" do
      assert [] = SessionParser.extract_files_from_tool_call(nil)
    end
  end

  describe "determine_status/2" do
    test "returns idle for nil message" do
      assert "idle" = SessionParser.determine_status(nil, [])
    end

    test "returns executing for pending tool calls" do
      message = %{
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "toolCall", "name" => "Read"}]
        }
      }
      assert "executing" = SessionParser.determine_status(message, [])
    end

    test "returns thinking after tool result" do
      message = %{"message" => %{"role" => "toolResult"}}
      assert "thinking" = SessionParser.determine_status(message, [])
    end

    test "returns processing for user message" do
      message = %{"message" => %{"role" => "user"}}
      assert "processing" = SessionParser.determine_status(message, [])
    end

    test "returns idle with no tool calls" do
      message = %{"message" => %{"role" => "assistant", "content" => []}}
      assert "idle" = SessionParser.determine_status(message, [])
    end

    test "returns active as default with tool calls" do
      message = %{"message" => %{"role" => "assistant", "content" => []}}
      assert "active" = SessionParser.determine_status(message, [%{name: "exec"}])
    end
  end

  describe "parse_timestamp/1" do
    test "parses ISO8601 string" do
      result = SessionParser.parse_timestamp("2024-01-15T10:30:00Z")
      assert result.year == 2024
      assert result.month == 1
      assert result.day == 15
    end

    test "parses millisecond timestamp" do
      result = SessionParser.parse_timestamp(1705315800000)
      assert %DateTime{} = result
    end

    test "returns current time for nil" do
      result = SessionParser.parse_timestamp(nil)
      assert DateTime.diff(DateTime.utc_now(), result, :second) < 2
    end

    test "passes through DateTime unchanged" do
      dt = DateTime.utc_now()
      assert dt == SessionParser.parse_timestamp(dt)
    end
  end

  describe "format_action/1" do
    test "returns nil for nil input" do
      assert nil == SessionParser.format_action(nil)
    end

    test "formats action with path" do
      action = %{name: "Read", arguments: %{"path" => "/test.ex"}, timestamp: nil}
      result = SessionParser.format_action(action)
      
      assert result.action == "Read"
      assert result.target == "/test.ex"
      assert %DateTime{} = result.timestamp
    end

    test "truncates long targets" do
      long_path = String.duplicate("a", 100)
      action = %{name: "Read", arguments: %{"path" => long_path}, timestamp: nil}
      result = SessionParser.format_action(action)
      
      assert String.length(result.target) <= 50
      assert String.ends_with?(result.target, "...")
    end
  end

  describe "truncate/2" do
    test "returns string unchanged if under max" do
      assert "short" = SessionParser.truncate("short", 10)
    end

    test "truncates with ellipsis if over max" do
      result = SessionParser.truncate("this is a very long string", 10)
      assert String.length(result) == 10
      assert String.ends_with?(result, "...")
    end

    test "handles non-string input" do
      assert "" = SessionParser.truncate(nil, 10)
      assert "" = SessionParser.truncate(123, 10)
    end
  end
end
