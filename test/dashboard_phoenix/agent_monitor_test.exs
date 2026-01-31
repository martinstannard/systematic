defmodule DashboardPhoenix.AgentMonitorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.AgentMonitor

  describe "detect_agent_type/1 logic" do
    test "detects claude agent" do
      assert detect_agent_type("claude --model opus") == "claude"
      assert detect_agent_type("/usr/bin/claude-code") == "claude"
      assert detect_agent_type("CLAUDE CODE") == "claude"
    end

    test "detects opencode agent" do
      assert detect_agent_type("opencode --model sonnet") == "opencode"
      assert detect_agent_type("/home/user/.local/bin/opencode") == "opencode"
    end

    test "detects codex agent" do
      assert detect_agent_type("codex generate tests") == "codex"
    end

    test "detects pi agent" do
      assert detect_agent_type("pi coding assistant") == "pi"
    end

    test "returns unknown for unrecognized command" do
      assert detect_agent_type("vim file.ex") == "unknown"
      assert detect_agent_type("bash script.sh") == "unknown"
      assert detect_agent_type("") == "unknown"
    end
  end

  describe "extract_task/1 logic" do
    test "extracts double-quoted task" do
      command = ~s(claude --task "Fix the bug in module")
      result = extract_task(command)
      assert result == "Fix the bug in module"
    end

    test "extracts single-quoted task" do
      command = ~s(opencode 'Implement feature X')
      result = extract_task(command)
      assert result == "Implement feature X"
    end

    test "truncates long quoted tasks" do
      long_task = String.duplicate("a", 150)
      command = ~s(claude "#{long_task}")
      result = extract_task(command)
      assert String.length(result) <= 80
      assert String.ends_with?(result, "...")
    end

    test "returns truncated command when no quotes" do
      command = "opencode --model sonnet --fast"
      result = extract_task(command)
      assert result == "opencode --model sonnet --fast"
    end

    test "truncates long unquoted commands" do
      long_command = String.duplicate("command ", 20)
      result = extract_task(long_command)
      assert String.length(result) <= 80
      assert String.ends_with?(result, "...")
    end
  end

  describe "truncate/2 logic" do
    test "returns string unchanged if under max length" do
      assert truncate("short", 10) == "short"
      assert truncate("exactly10!", 10) == "exactly10!"
    end

    test "truncates and adds ellipsis if over max length" do
      result = truncate("this is a long string", 10)
      assert String.length(result) == 10
      assert String.ends_with?(result, "...")
    end

    test "handles empty string" do
      assert truncate("", 10) == ""
    end

    test "handles string at boundary" do
      assert truncate("123456789", 9) == "123456789"
      assert truncate("1234567890", 9) == "123456..."
    end
  end

  describe "is_agent_process?/1 logic" do
    test "matches claude processes" do
      assert is_agent_process?("user 1234 0.5 1.0 claude --model opus") == true
    end

    test "matches opencode processes" do
      assert is_agent_process?("user 1234 0.5 1.0 opencode acp --port 9100") == true
    end

    test "matches codex processes" do
      assert is_agent_process?("user 1234 0.5 1.0 codex generate") == true
    end

    test "matches pi coding processes" do
      assert is_agent_process?("user 1234 0.5 1.0 pi coding assistant") == true
    end

    test "excludes grep commands" do
      assert is_agent_process?("user 1234 0.5 1.0 grep claude") == false
      assert is_agent_process?("user 1234 0.5 1.0 grep opencode") == false
    end

    test "excludes ps aux commands" do
      assert is_agent_process?("user 1234 0.5 1.0 ps aux | grep claude") == false
    end

    test "does not match regular processes" do
      assert is_agent_process?("user 1234 0.5 1.0 vim file.ex") == false
      assert is_agent_process?("user 1234 0.5 1.0 /bin/bash") == false
    end
  end

  describe "module structure" do
    test "module is defined" do
      # AgentMonitor module should be defined and compiled
      assert Code.ensure_loaded?(AgentMonitor)
    end

    test "expected public function exists" do
      # list_active_agents is the main public API
      funcs = AgentMonitor.__info__(:functions)
      assert {:list_active_agents, 0} in funcs
    end
  end

  # Implementations mirroring the private function logic
  @agent_patterns ~w(claude opencode codex pi\ coding)

  defp detect_agent_type(command) do
    cmd_lower = String.downcase(command)
    cond do
      String.contains?(cmd_lower, "claude") -> "claude"
      String.contains?(cmd_lower, "opencode") -> "opencode"
      String.contains?(cmd_lower, "codex") -> "codex"
      String.contains?(cmd_lower, "pi ") -> "pi"
      true -> "unknown"
    end
  end

  defp extract_task(command) do
    cond do
      String.contains?(command, "\"") ->
        case Regex.run(~r/"([^"]{1,100})"/, command) do
          [_, task] -> truncate(task, 80)
          _ -> truncate(command, 80)
        end
      String.contains?(command, "'") ->
        case Regex.run(~r/'([^']{1,100})'/, command) do
          [_, task] -> truncate(task, 80)
          _ -> truncate(command, 80)
        end
      true ->
        truncate(command, 80)
    end
  end

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end

  defp is_agent_process?(line) do
    contains_patterns?(line, @agent_patterns) and
      not String.contains?(String.downcase(line), "grep") and
      not String.contains?(String.downcase(line), "ps aux")
  end

  defp contains_patterns?(line, patterns) do
    line_lower = String.downcase(line)
    Enum.any?(patterns, &String.contains?(line_lower, String.downcase(&1)))
  end
end
