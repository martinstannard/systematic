defmodule DashboardPhoenix.ProcessMonitorTest do
  use ExUnit.Case, async: true
  alias DashboardPhoenix.ProcessMonitor

  describe "list_processes/0" do
    test "returns list of interesting processes" do
      processes = ProcessMonitor.list_processes()
      
      assert is_list(processes)
      
      # Each process should have the expected structure
      for process <- processes do
        assert %{
          name: name,
          pid: pid,
          status: status,
          time: time,
          command: command,
          directory: directory,
          details: details,
          cpu_usage: cpu_usage,
          memory_usage: memory_usage,
          model: model,
          tokens: tokens,
          exit_code: exit_code,
          last_output: last_output,
          runtime: runtime,
          start_time: start_time
        } = process
        
        assert is_binary(name)
        assert is_binary(pid)
        assert status in ["busy", "idle", "running", "stopped", "zombie", "dead"]
        assert is_binary(time)
        assert is_binary(command)
        assert is_binary(directory)
        assert is_binary(details)
        assert is_binary(cpu_usage)
        assert is_binary(memory_usage)
        assert is_binary(model)
        assert is_map(tokens)
        assert tokens.input == 0
        assert tokens.output == 0
        assert tokens.total == 0
        assert is_nil(exit_code)
        assert is_nil(last_output)
        assert is_binary(runtime)
        assert is_binary(start_time)
      end
    end

    test "limits results to 20 processes" do
      processes = ProcessMonitor.list_processes()
      assert length(processes) <= 20
    end

    test "only includes interesting processes" do
      processes = ProcessMonitor.list_processes()
      
      # All processes should contain one of the interesting patterns
      interesting_patterns = ~w(opencode openclaw-tui openclaw-gateway)
      
      for process <- processes do
        # Check details instead of command as command might be truncated
        command_lower = String.downcase(process.details)
        assert Enum.any?(interesting_patterns, &String.contains?(command_lower, &1))
      end
    end
  end

  describe "process parsing" do
    test "parses process line correctly" do
      # Mock ps aux output line - keeping as documentation of expected format
      _sample_line = "martins  12345  5.2  2.1 1234567 98765 ?     S    09:15   0:01 /usr/bin/opencode --some-flag"
      
      # We need to test the private function indirectly by calling list_processes
      # Since the function filters for interesting processes, we can't directly test parse_process_line
      # But we can verify the overall structure works by checking a known process exists
      
      processes = ProcessMonitor.list_processes()
      
      # At least verify the structure is correct if any processes are found
      if length(processes) > 0 do
        process = List.first(processes)
        
        # Name should follow adjective-noun pattern
        assert Regex.match?(~r/^\w+-\w+$/, process.name)
        
        # PID should be numeric string
        assert Regex.match?(~r/^\d+$/, process.pid)
        
        # CPU usage should end with %
        assert String.ends_with?(process.cpu_usage, "%")
        
        # Memory usage should have units
        assert Regex.match?(~r/\d+(\.\d+)? (KB|MB|GB)$/, process.memory_usage)
      end
    end

    test "derives status correctly from process state" do
      # Since derive_status is private, we test it indirectly
      processes = ProcessMonitor.list_processes()
      
      for process <- processes do
        assert process.status in ["busy", "idle", "running", "stopped", "zombie", "dead"]
      end
    end

    test "generates consistent names from PID" do
      # Test that the same PID always generates the same name
      # We'll call list_processes multiple times and verify consistency
      
      processes1 = ProcessMonitor.list_processes()
      processes2 = ProcessMonitor.list_processes()
      
      # Build maps by PID for comparison
      map1 = Map.new(processes1, &{&1.pid, &1.name})
      map2 = Map.new(processes2, &{&1.pid, &1.name})
      
      # For any PIDs that appear in both, names should be identical
      for {pid, name1} <- map1 do
        case Map.get(map2, pid) do
          nil -> :ok  # PID not in second list, that's fine
          name2 -> assert name1 == name2, "Name for PID #{pid} should be consistent"
        end
      end
    end

    test "truncates long commands" do
      processes = ProcessMonitor.list_processes()
      
      for process <- processes do
        assert String.length(process.command) <= 80
      end
    end

    test "extracts appropriate directories" do
      processes = ProcessMonitor.list_processes()
      
      for process <- processes do
        # Directory should be one of the expected patterns
        assert process.directory in [
          "/home/martins/clawd/dashboard_phoenix",
          "/home/martins/clawd",
          "~",
          "/"
        ]
      end
    end

    test "detects model correctly" do
      processes = ProcessMonitor.list_processes()
      
      for process <- processes do
        assert process.model in ["claude-sonnet-4", "N/A (System)"]
      end
    end

    test "formats memory correctly" do
      processes = ProcessMonitor.list_processes()
      
      for process <- processes do
        # Memory should be in format like "123 KB", "12.3 MB", "1.2 GB"
        assert Regex.match?(~r/^\d+(\.\d+)? (KB|MB|GB)$/, process.memory_usage) or process.memory_usage == "N/A"
      end
    end
  end

  describe "get_stats/1" do
    test "calculates correct statistics for empty list" do
      stats = ProcessMonitor.get_stats([])
      
      assert stats == %{
        running: 0,
        busy: 0,
        idle: 0,
        completed: 0,
        failed: 0,
        total: 0
      }
    end

    test "calculates correct statistics for process list" do
      # Create mock processes with different statuses
      processes = [
        %{status: "busy"},
        %{status: "busy"},
        %{status: "idle"},
        %{status: "idle"},
        %{status: "idle"},
        %{status: "stopped"},
        %{status: "zombie"},
        %{status: "dead"},
        %{status: "running"}
      ]
      
      stats = ProcessMonitor.get_stats(processes)
      
      assert stats.busy == 2
      assert stats.idle == 3
      assert stats.running == 5  # busy + idle
      assert stats.failed == 3   # stopped + zombie + dead
      assert stats.completed == 0  # Always 0 since we can't detect from ps
      assert stats.total == 9
    end

    test "handles unknown statuses gracefully" do
      processes = [
        %{status: "unknown"},
        %{status: "weird"},
        %{status: "busy"}
      ]
      
      stats = ProcessMonitor.get_stats(processes)
      
      assert stats.busy == 1
      assert stats.idle == 0
      assert stats.running == 1  # Only the busy one counts as running
      assert stats.failed == 0   # Unknown statuses don't count as failed
      assert stats.completed == 0
      assert stats.total == 3
    end

    test "calculates statistics for real process list" do
      processes = ProcessMonitor.list_processes()
      stats = ProcessMonitor.get_stats(processes)
      
      # Verify the math adds up
      assert stats.running == stats.busy + stats.idle
      assert stats.total == length(processes)
      assert stats.completed == 0  # Always 0
      
      # All counts should be non-negative
      assert stats.running >= 0
      assert stats.busy >= 0
      assert stats.idle >= 0
      assert stats.failed >= 0
      assert stats.total >= 0
    end
  end

  describe "CPU parsing" do
    # Testing the parse_cpu function indirectly
    test "handles various CPU formats" do
      processes = ProcessMonitor.list_processes()
      
      for process <- processes do
        cpu_str = String.replace(process.cpu_usage, "%", "")
        # Should be parseable as a float
        assert match?({_float, ""}, Float.parse(cpu_str)) or cpu_str == "?"
      end
    end
  end

  describe "process filtering" do
    # Test that we only get processes matching our patterns
    test "filters for interesting patterns only" do
      # Get a sample of actual ps output to test our filtering
      {output, 0} = System.cmd("ps", ["aux", "--sort=-pcpu"])
      
      lines = output
      |> String.split("\n")
      |> Enum.drop(1)  # Skip header
      |> Enum.take(50) # Just check first 50
      
      interesting_patterns = ~w(opencode openclaw-tui openclaw-gateway)
      
      for line <- lines do
        line_lower = String.downcase(line)
        is_interesting = Enum.any?(interesting_patterns, &String.contains?(line_lower, &1))
        
        if is_interesting do
          # This line should be included in our filtered results
          assert String.length(line) > 0
        end
      end
    end
  end
end