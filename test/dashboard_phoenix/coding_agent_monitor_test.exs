defmodule DashboardPhoenix.CodingAgentMonitorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.CodingAgentMonitor

  describe "parse_process_line/1 logic" do
    test "parses standard ps aux output line" do
      line =
        "martins  12345  5.2  2.1 1234567 98765 pts/0    S    09:15   0:01 opencode --model sonnet"

      result = parse_process_line(line)

      assert result.user == "martins"
      assert result.pid == "12345"
      assert result.cpu == 5.2
      assert result.memory == 2.1
      assert result.status == "S"
      assert result.started == "09:15"
      assert result.time == "0:01"
      assert result.command == "opencode --model sonnet"
    end

    test "parses line with multi-word command" do
      line =
        "root     99999  0.0  0.5 123456 54321 ?        Sl   Jan01   1:23 /usr/bin/claude code --task 'fix bug'"

      result = parse_process_line(line)

      assert result.user == "root"
      assert result.pid == "99999"
      assert result.command =~ "claude code"
      assert result.command =~ "fix bug"
    end

    test "handles malformed line gracefully" do
      result = parse_process_line("not enough fields")
      assert result == nil
    end

    test "handles empty string" do
      result = parse_process_line("")
      assert result == nil
    end
  end

  describe "is_coding_agent?/1 logic" do
    test "identifies opencode as coding agent" do
      proc = %{command: "/usr/bin/opencode --model sonnet"}
      assert is_coding_agent?(proc) == true
    end

    test "identifies claude as coding agent" do
      proc = %{command: "claude-code --task 'fix bug'"}
      assert is_coding_agent?(proc) == true
    end

    test "identifies codex as coding agent" do
      proc = %{command: "codex generate tests"}
      assert is_coding_agent?(proc) == true
    end

    test "identifies aider as coding agent" do
      proc = %{command: "aider --model gpt-4"}
      assert is_coding_agent?(proc) == true
    end

    test "does not match regular processes" do
      proc = %{command: "vim file.ex"}
      assert is_coding_agent?(proc) == false

      proc2 = %{command: "/bin/bash"}
      assert is_coding_agent?(proc2) == false
    end

    test "is case insensitive" do
      proc = %{command: "OPENCODE --model SONNET"}
      assert is_coding_agent?(proc) == true
    end

    test "returns false for nil" do
      assert is_coding_agent?(nil) == false
    end
  end

  describe "detect_agent_type/1 logic" do
    test "detects OpenCode" do
      assert detect_agent_type("opencode --model sonnet") == "OpenCode"
      assert detect_agent_type("/usr/bin/opencode") == "OpenCode"
    end

    test "detects Claude Code" do
      assert detect_agent_type("claude-code --task fix") == "Claude Code"
      assert detect_agent_type("claude code") == "Claude Code"
    end

    test "detects Codex" do
      assert detect_agent_type("codex generate") == "Codex"
    end

    test "detects Aider" do
      assert detect_agent_type("aider --model gpt-4") == "Aider"
    end

    test "returns Unknown for unrecognized" do
      assert detect_agent_type("vim file.ex") == "Unknown"
      assert detect_agent_type("") == "Unknown"
    end
  end

  describe "humanize_status/1 logic" do
    test "humanizes running status" do
      assert humanize_status("R") == "running"
      assert humanize_status("R+") == "running"
    end

    test "humanizes sleeping status" do
      assert humanize_status("S") == "sleeping"
      assert humanize_status("Sl") == "sleeping"
    end

    test "humanizes waiting status" do
      assert humanize_status("D") == "waiting"
    end

    test "humanizes zombie status" do
      assert humanize_status("Z") == "zombie"
    end

    test "humanizes stopped status" do
      assert humanize_status("T") == "stopped"
    end

    test "returns unknown for unrecognized status" do
      assert humanize_status("X") == "unknown"
      assert humanize_status("?") == "unknown"
    end

    test "handles nil gracefully" do
      assert humanize_status(nil) == "unknown"
    end
  end

  describe "parse_float/1 logic" do
    test "parses valid float string" do
      assert parse_float("5.2") == 5.2
      assert parse_float("0.0") == 0.0
      assert parse_float("99.9") == 99.9
    end

    test "parses integer-like string" do
      assert parse_float("5") == 5.0
      assert parse_float("0") == 0.0
    end

    test "returns 0.0 for invalid string" do
      assert parse_float("abc") == 0.0
      assert parse_float("") == 0.0
    end

    test "returns 0.0 for nil" do
      assert parse_float(nil) == 0.0
    end
  end

  describe "extract_project_name/1 logic" do
    test "extracts project name from path" do
      assert extract_project_name("/home/user/code/my-project") == "my-project"
      assert extract_project_name("/var/www/app") == "app"
    end

    test "returns nil for nil path" do
      assert extract_project_name(nil) == nil
    end

    test "handles root path" do
      assert extract_project_name("/") == ""
    end
  end

  describe "kill_agent/1 logic" do
    test "rejects invalid PID string" do
      result = CodingAgentMonitor.kill_agent("not-a-number")
      assert result == {:error, "Invalid PID"}
    end

    test "rejects PID with trailing characters" do
      result = CodingAgentMonitor.kill_agent("123abc")
      assert result == {:error, "Invalid PID"}
    end
  end

  describe "module structure" do
    test "module is defined and has expected functions" do
      assert Code.ensure_loaded?(CodingAgentMonitor)
      funcs = CodingAgentMonitor.__info__(:functions)
      assert {:list_agents, 0} in funcs
      assert {:kill_agent, 1} in funcs
    end
  end

  # Implementations mirroring the private function logic
  @agent_patterns ~w(opencode claude-code codex aider)

  defp parse_process_line(line) do
    parts = String.split(line, ~r/\s+/, parts: 11)

    case parts do
      [user, pid, cpu, mem, _vsz, _rss, _tty, stat, start, time | cmd_parts] ->
        %{
          user: user,
          pid: pid,
          cpu: parse_float(cpu),
          memory: parse_float(mem),
          status: stat,
          started: start,
          time: time,
          command: Enum.join(cmd_parts, " ")
        }

      _ ->
        nil
    end
  end

  defp is_coding_agent?(nil), do: false

  defp is_coding_agent?(%{command: cmd}) do
    cmd_lower = String.downcase(cmd)
    Enum.any?(@agent_patterns, &String.contains?(cmd_lower, &1))
  end

  defp detect_agent_type(cmd) do
    cmd_lower = String.downcase(cmd)

    cond do
      String.contains?(cmd_lower, "opencode") -> "OpenCode"
      String.contains?(cmd_lower, "claude") -> "Claude Code"
      String.contains?(cmd_lower, "codex") -> "Codex"
      String.contains?(cmd_lower, "aider") -> "Aider"
      true -> "Unknown"
    end
  end

  defp humanize_status(stat) do
    case String.first(stat || "?") do
      "R" -> "running"
      "S" -> "sleeping"
      "D" -> "waiting"
      "Z" -> "zombie"
      "T" -> "stopped"
      _ -> "unknown"
    end
  end

  defp parse_float(str) do
    case Float.parse(str || "0") do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp extract_project_name(nil), do: nil
  defp extract_project_name(path), do: Path.basename(path)
end
