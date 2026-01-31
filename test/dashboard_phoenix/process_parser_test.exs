defmodule DashboardPhoenix.ProcessParserTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.ProcessParser

  describe "parse_process_line/1" do
    test "parses valid ps aux output line" do
      line = "martin   12345  15.2  4.8  123456  98765 pts/0   R+   10:30   0:05 opencode session start"
      
      result = ProcessParser.parse_process_line(line)
      
      assert %{
        user: "martin",
        pid: "12345",
        cpu: 15.2,
        mem: 4.8,
        vsz: "123456",
        rss: "98765", 
        tty: "pts/0",
        stat: "R+",
        start: "10:30",
        time: "0:05",
        command: "opencode session start"
      } = result
    end

    test "parses line with command containing spaces" do
      line = "root     1001   0.1  0.2   4568   2048  ?      S    09:45   0:00 /usr/bin/systemd --user"
      
      result = ProcessParser.parse_process_line(line)
      
      assert result.command == "/usr/bin/systemd --user"
      assert result.pid == "1001"
    end

    test "returns nil for invalid line with too few parts" do
      line = "invalid line"
      
      result = ProcessParser.parse_process_line(line)
      
      assert result == nil
    end

    test "returns nil for non-string input" do
      assert ProcessParser.parse_process_line(nil) == nil
      assert ProcessParser.parse_process_line(12345) == nil
    end

    test "handles non-numeric CPU and memory values" do
      line = "martin   12345  N/A  N/A  123456  98765 pts/0   R+   10:30   0:05 opencode"
      
      result = ProcessParser.parse_process_line(line)
      
      assert result.cpu == 0.0
      assert result.mem == 0.0
    end
  end

  describe "parse_float/1" do
    test "parses valid float strings" do
      assert ProcessParser.parse_float("15.2") == 15.2
      assert ProcessParser.parse_float("0.0") == 0.0
      assert ProcessParser.parse_float("100") == 100.0
    end

    test "returns 0.0 for invalid input" do
      assert ProcessParser.parse_float("N/A") == 0.0
      assert ProcessParser.parse_float("") == 0.0
      assert ProcessParser.parse_float(nil) == 0.0
    end
  end

  describe "derive_status/2" do
    test "detects zombie processes" do
      assert ProcessParser.derive_status("Z+", 0.0) == "zombie"
      assert ProcessParser.derive_status("ZN", 5.0) == "zombie"
    end

    test "detects stopped processes" do
      assert ProcessParser.derive_status("T", 0.0) == "stopped"
      assert ProcessParser.derive_status("T+", 2.5) == "stopped"
    end

    test "detects dead processes" do
      assert ProcessParser.derive_status("X", 0.0) == "dead"
    end

    test "detects running/busy processes" do
      assert ProcessParser.derive_status("R", 10.0) == "busy"
      assert ProcessParser.derive_status("R+", 0.5) == "busy"
    end

    test "detects sleeping processes as busy if high CPU" do
      assert ProcessParser.derive_status("S", 15.0) == "busy"
      assert ProcessParser.derive_status("D", 8.0) == "busy"
    end

    test "detects sleeping processes as idle if low CPU" do
      assert ProcessParser.derive_status("S", 2.0) == "idle"
      assert ProcessParser.derive_status("D", 0.1) == "idle"
      assert ProcessParser.derive_status("Ss", 1.5) == "idle"
    end

    test "defaults to running for unknown states" do
      assert ProcessParser.derive_status("?", 5.0) == "running"
      assert ProcessParser.derive_status("Unknown", 0.0) == "running"
    end

    test "handles default CPU value" do
      assert ProcessParser.derive_status("S") == "idle"
    end
  end

  describe "format_memory/1" do
    test "formats memory in GB for large values" do
      assert ProcessParser.format_memory("2048000") == "2.0 GB"
      assert ProcessParser.format_memory("1500000") == "1.5 GB"
    end

    test "formats memory in MB for medium values" do
      assert ProcessParser.format_memory("2048") == "2.0 MB"
      assert ProcessParser.format_memory("1500") == "1.5 MB"
    end

    test "formats memory in KB for small values" do
      assert ProcessParser.format_memory("512") == "512 KB"
      assert ProcessParser.format_memory("100") == "100 KB"
    end

    test "returns N/A for invalid input" do
      assert ProcessParser.format_memory("invalid") == "N/A"
      assert ProcessParser.format_memory(nil) == "N/A"
      assert ProcessParser.format_memory(12345) == "N/A"
    end
  end

  describe "generate_name/1" do
    test "generates consistent names for same PID" do
      name1 = ProcessParser.generate_name("1234")
      name2 = ProcessParser.generate_name("1234")
      
      assert name1 == name2
      assert String.contains?(name1, "-")
    end

    test "generates different names for different PIDs" do
      name1 = ProcessParser.generate_name("1234")
      name2 = ProcessParser.generate_name("5678")
      
      assert name1 != name2
    end

    test "handles invalid PID input" do
      assert ProcessParser.generate_name("invalid") == "unknown-process"
      assert ProcessParser.generate_name(nil) == "unknown-process"
    end
  end

  describe "truncate_command/2" do
    test "truncates long commands" do
      long_command = String.duplicate("a", 100)
      result = ProcessParser.truncate_command(long_command, 50)
      
      assert String.length(result) <= 50
    end

    test "removes long flags" do
      command = "opencode --session-token=very_long_token_value session start"
      result = ProcessParser.truncate_command(command)
      
      refute String.contains?(result, "--session-token=")
      assert String.contains?(result, "opencode")
      assert String.contains?(result, "session start")
    end

    test "normalizes whitespace" do
      command = "opencode    session     start"
      result = ProcessParser.truncate_command(command)
      
      assert result == "opencode session start"
    end

    test "handles non-string input" do
      assert ProcessParser.truncate_command(nil) == ""
      assert ProcessParser.truncate_command(12345) == ""
    end
  end

  describe "contains_patterns?/2" do
    test "matches patterns case-insensitively" do
      assert ProcessParser.contains_patterns?("OpenCode session", ["opencode"])
      assert ProcessParser.contains_patterns?("CLAUDE coding", ["claude"])
    end

    test "returns true if any pattern matches" do
      assert ProcessParser.contains_patterns?("vim editor opencode", ["opencode", "emacs"])
      assert ProcessParser.contains_patterns?("claude session", ["nonexistent", "claude"])
    end

    test "returns false if no patterns match" do
      refute ProcessParser.contains_patterns?("vim editor", ["opencode", "claude"])
      refute ProcessParser.contains_patterns?("systemd process", ["coding"])
    end

    test "handles empty patterns list" do
      refute ProcessParser.contains_patterns?("any text", [])
    end

    test "handles invalid input" do
      refute ProcessParser.contains_patterns?(nil, ["opencode"])
      refute ProcessParser.contains_patterns?("text", nil)
    end
  end

  describe "interesting?/2" do
    test "works with process line strings" do
      assert ProcessParser.interesting?("opencode session start", ["opencode"])
      refute ProcessParser.interesting?("vim editor", ["opencode", "claude"])
    end

    test "works with parsed process maps" do
      process = %{command: "opencode session start", pid: "1234"}
      assert ProcessParser.interesting?(process, ["opencode"])

      process2 = %{command: "vim editor", pid: "5678"}
      refute ProcessParser.interesting?(process2, ["opencode", "claude"])
    end

    test "handles invalid input" do
      refute ProcessParser.interesting?(nil, ["opencode"])
      refute ProcessParser.interesting?(%{other: "data"}, ["opencode"])
    end
  end

  describe "list_processes/1" do
    # Note: These tests would require mocking CommandRunner.run/3
    # For integration testing, we'd test with actual ps output
    
    test "accepts filter function option" do
      # This would require mocking in a full test suite
      # For now, we just verify the function exists and accepts options
      assert function_exported?(ProcessParser, :list_processes, 1)
    end

    test "accepts sort option" do
      assert function_exported?(ProcessParser, :list_processes, 1)
    end

    test "accepts limit option" do
      assert function_exported?(ProcessParser, :list_processes, 1)
    end
  end
end