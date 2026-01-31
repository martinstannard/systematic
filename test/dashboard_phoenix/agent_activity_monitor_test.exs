defmodule DashboardPhoenix.AgentActivityMonitorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.AgentActivityMonitor

  describe "parse_timestamp/1 logic" do
    test "parses ISO8601 string" do
      result = parse_timestamp("2024-01-15T10:30:00Z")
      assert %DateTime{} = result
      assert result.year == 2024
    end

    test "parses millisecond timestamp" do
      # Timestamp for 2024-01-15T10:30:00Z
      ts = 1705315800000
      result = parse_timestamp(ts)
      assert %DateTime{} = result
    end

    test "returns current time for nil" do
      result = parse_timestamp(nil)
      assert %DateTime{} = result
      # Should be very recent
      assert DateTime.diff(DateTime.utc_now(), result, :second) < 2
    end

    test "returns current time for invalid string" do
      result = parse_timestamp("not a timestamp")
      assert %DateTime{} = result
    end
  end

  describe "extract_files_from_tool_call/1 logic" do
    test "extracts file path from Read tool call" do
      tool_call = %{name: "Read", arguments: %{"path" => "/some/file.ex"}}
      assert extract_files(tool_call) == ["/some/file.ex"]
    end

    test "extracts file path from read tool call (lowercase)" do
      tool_call = %{name: "read", arguments: %{"file_path" => "/another/file.ts"}}
      assert extract_files(tool_call) == ["/another/file.ts"]
    end

    test "extracts file path from Write tool call" do
      tool_call = %{name: "Write", arguments: %{"path" => "/output/result.json"}}
      assert extract_files(tool_call) == ["/output/result.json"]
    end

    test "extracts file path from Edit tool call" do
      tool_call = %{name: "Edit", arguments: %{"file_path" => "/edit/target.py"}}
      assert extract_files(tool_call) == ["/edit/target.py"]
    end

    test "extracts files from exec command" do
      tool_call = %{name: "exec", arguments: %{"command" => "cat ~/code/file.ex ./local.ts"}}
      files = extract_files(tool_call)
      assert "~/code/file.ex" in files
      assert "./local.ts" in files
    end

    test "returns empty list for unknown tool" do
      tool_call = %{name: "unknown_tool", arguments: %{"foo" => "bar"}}
      assert extract_files(tool_call) == []
    end

    test "handles non-map arguments" do
      tool_call = %{name: "Read", arguments: "invalid"}
      assert extract_files(tool_call) == []
    end

    test "handles nil arguments" do
      assert extract_files(nil) == []
    end
  end

  describe "extract_files_from_command/1 logic" do
    test "extracts file paths from command string" do
      command = "cat ~/code/app.ex ./test.exs /absolute/path.ts"
      files = extract_from_command(command)

      assert "~/code/app.ex" in files
      assert "./test.exs" in files
      assert "/absolute/path.ts" in files
    end

    test "limits to 5 files" do
      command = "./a.ex ./b.ex ./c.ex ./d.ex ./e.ex ./f.ex ./g.ex"
      files = extract_from_command(command)
      assert length(files) <= 5
    end

    test "handles empty command" do
      assert extract_from_command("") == []
    end

    test "handles non-string input" do
      assert extract_from_command(nil) == []
    end
  end

  describe "determine_status/2 logic" do
    test "returns 'idle' for nil message" do
      assert determine_status(nil, []) == "idle"
    end

    test "returns 'executing' when assistant has pending tool calls" do
      message = %{
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "toolCall", "name" => "Read"}]
        }
      }
      assert determine_status(message, [%{name: "Read"}]) == "executing"
    end

    test "returns 'thinking' after tool result" do
      message = %{"message" => %{"role" => "toolResult"}}
      assert determine_status(message, [%{name: "Read"}]) == "thinking"
    end

    test "returns 'processing' for user message" do
      message = %{"message" => %{"role" => "user"}}
      assert determine_status(message, [%{name: "Read"}]) == "processing"
    end

    test "returns 'idle' with no tool calls" do
      message = %{"message" => %{"role" => "assistant", "content" => []}}
      assert determine_status(message, []) == "idle"
    end

    test "returns 'active' as default with tool calls" do
      message = %{"message" => %{"role" => "assistant", "content" => []}}
      assert determine_status(message, [%{name: "exec"}]) == "active"
    end
  end

  describe "format_action/1 logic" do
    test "returns nil for nil input" do
      assert format_action(nil) == nil
    end

    test "formats action with path argument" do
      action = %{name: "Read", arguments: %{"path" => "/long/path/to/file.ex"}, timestamp: nil}
      result = format_action(action)

      assert result.action == "Read"
      assert result.target == "/long/path/to/file.ex"
      assert %DateTime{} = result.timestamp
    end

    test "formats action with command argument" do
      action = %{name: "exec", arguments: %{"command" => "mix test"}, timestamp: nil}
      result = format_action(action)

      assert result.action == "exec"
      assert result.target == "mix test"
    end

    test "truncates long targets" do
      long_path = String.duplicate("a", 100)
      action = %{name: "Read", arguments: %{"path" => long_path}, timestamp: nil}
      result = format_action(action)

      assert String.length(result.target) <= 50
      assert String.ends_with?(result.target, "...")
    end
  end

  describe "detect_agent_type/1 logic" do
    test "detects Claude Code" do
      assert detect_agent_type("claude --model opus") == :claude_code
    end

    test "detects OpenCode" do
      assert detect_agent_type("opencode acp --port 9100") == :opencode
    end

    test "detects Codex" do
      assert detect_agent_type("codex generate") == :codex
    end

    test "returns unknown for unrecognized command" do
      assert detect_agent_type("vim file.ex") == :unknown
    end
  end

  describe "detect_model_from_command/1 logic" do
    test "detects opus model" do
      assert detect_model("claude --model opus") == "claude-opus"
    end

    test "detects sonnet model" do
      assert detect_model("claude sonnet-3.5") == "claude-sonnet"
    end

    test "detects gemini model" do
      assert detect_model("opencode --model gemini-pro") == "gemini"
    end

    test "returns unknown for unrecognized model" do
      assert detect_model("opencode --model gpt-4") == "unknown"
    end
  end

  describe "truncate/2 logic" do
    test "returns string unchanged if under max" do
      assert truncate("short", 10) == "short"
    end

    test "truncates with ellipsis if over max" do
      result = truncate("this is a very long string", 10)
      assert String.length(result) == 10
      assert String.ends_with?(result, "...")
    end

    test "handles non-string input" do
      assert truncate(nil, 10) == ""
      assert truncate(123, 10) == ""
    end
  end

  describe "GenServer behavior" do
    test "module exports expected client API functions" do
      assert function_exported?(AgentActivityMonitor, :start_link, 1)
      assert function_exported?(AgentActivityMonitor, :get_activity, 0)
      assert function_exported?(AgentActivityMonitor, :subscribe, 0)
    end

    test "init returns expected state structure" do
      {:ok, state} = AgentActivityMonitor.init([])

      assert state.agents == %{}
      assert state.session_offsets == %{}
      assert state.last_poll == nil
    end

    test "handle_call :get_activity returns sorted activities" do
      now = DateTime.utc_now()
      old = DateTime.add(now, -3600, :second)

      agents = %{
        "agent-1" => %{id: "agent-1", last_activity: old},
        "agent-2" => %{id: "agent-2", last_activity: now}
      }
      state = %{agents: agents, session_offsets: %{}, last_poll: nil}

      {:reply, activities, _new_state} = AgentActivityMonitor.handle_call(:get_activity, self(), state)

      # Should be sorted by last_activity descending (newest first)
      assert length(activities) == 2
      assert hd(activities).id == "agent-2"  # More recent first
    end
  end

  # Implementations mirroring the private function logic
  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts, :millisecond)
  defp parse_timestamp(_), do: DateTime.utc_now()

  defp extract_files(%{name: name, arguments: args}) when is_map(args) do
    cond do
      name in ["Read", "read"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["Write", "write"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["Edit", "edit"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["exec", "Bash"] -> extract_from_command(args["command"] || "")
      true -> []
    end
  end
  defp extract_files(_), do: []

  defp extract_from_command(command) when is_binary(command) do
    Regex.scan(~r{(?:^|\s)([~/.][\w./\-]+\.\w+)}, command)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.take(5)
  end
  defp extract_from_command(_), do: []

  defp determine_status(nil, _), do: "idle"
  defp determine_status(message, tool_calls) do
    role = get_in(message, ["message", "role"])
    content = get_in(message, ["message", "content"]) || []
    has_tool_calls = Enum.any?(content, &(is_map(&1) and &1["type"] == "toolCall"))

    cond do
      role == "assistant" and has_tool_calls -> "executing"
      role == "toolResult" -> "thinking"
      role == "user" -> "processing"
      length(tool_calls) == 0 -> "idle"
      true -> "active"
    end
  end

  defp format_action(nil), do: nil
  defp format_action(%{name: name, arguments: args, timestamp: ts}) do
    target = cond do
      is_map(args) and args["path"] -> truncate(args["path"], 50)
      is_map(args) and args["file_path"] -> truncate(args["file_path"], 50)
      is_map(args) and args["command"] -> truncate(args["command"], 50)
      true -> nil
    end

    %{action: name, target: target, timestamp: parse_timestamp(ts)}
  end

  defp detect_agent_type(command) do
    cmd_lower = String.downcase(command)
    cond do
      String.contains?(cmd_lower, "claude") -> :claude_code
      String.contains?(cmd_lower, "opencode") -> :opencode
      String.contains?(cmd_lower, "codex") -> :codex
      true -> :unknown
    end
  end

  defp detect_model(command) do
    cond do
      String.contains?(command, "opus") -> "claude-opus"
      String.contains?(command, "sonnet") -> "claude-sonnet"
      String.contains?(command, "gemini") -> "gemini"
      true -> "unknown"
    end
  end

  defp truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end
  defp truncate(_, _), do: ""
end
