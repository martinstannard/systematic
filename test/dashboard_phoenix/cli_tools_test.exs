defmodule DashboardPhoenix.CLIToolsTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.CLITools

  setup do
    # Ensure the ETS table exists for testing
    CLITools.ensure_cache_table()
    :ok
  end

  describe "check_tool/1" do
    test "returns {:ok, path} for existing tools like 'ls'" do
      assert {:ok, path} = CLITools.check_tool("ls")
      assert is_binary(path)
      assert String.ends_with?(path, "ls")
    end

    test "returns {:error, :not_found} for non-existent tools" do
      # Using a definitely non-existent command name
      result = CLITools.check_tool("definitely_not_a_real_command_xyz123")
      assert {:error, :not_found} = result
    end

    test "caches results for repeated calls" do
      # First call
      result1 = CLITools.check_tool("ls")
      # Second call should be cached
      result2 = CLITools.check_tool("ls")
      assert result1 == result2
    end
  end

  describe "check_tool/2" do
    test "includes friendly name in error tuple" do
      result = CLITools.check_tool("nonexistent_tool_abc", "My Cool Tool")
      assert {:error, {:not_found, "My Cool Tool"}} = result
    end

    test "returns ok tuple unchanged for existing tools" do
      assert {:ok, path} = CLITools.check_tool("ls", "List Command")
      assert is_binary(path)
    end
  end

  describe "check_tools/1" do
    test "returns all_available?: true when all tools exist" do
      result =
        CLITools.check_tools([
          {"ls", "List"},
          {"cat", "Cat"}
        ])

      assert result.all_available? == true
      assert length(result.available) == 2
      assert Enum.empty?(result.missing)
    end

    test "returns all_available?: false when some tools missing" do
      result =
        CLITools.check_tools([
          {"ls", "List"},
          {"nonexistent_tool_xyz", "Missing Tool"}
        ])

      assert result.all_available? == false
      assert length(result.available) == 1
      assert length(result.missing) == 1

      # Check the missing tool is properly identified
      assert [{"Missing Tool", :not_found}] = result.missing
    end

    test "returns all_available?: false when all tools missing" do
      result =
        CLITools.check_tools([
          {"nonexistent_tool_a", "Tool A"},
          {"nonexistent_tool_b", "Tool B"}
        ])

      assert result.all_available? == false
      assert Enum.empty?(result.available)
      assert length(result.missing) == 2
    end
  end

  describe "format_status_message/1" do
    test "reports all tools available when none missing" do
      status = %{available: [{"git", "/usr/bin/git"}], missing: []}
      message = CLITools.format_status_message(status)
      assert message =~ "All CLI tools available"
      assert message =~ "1 tools"
    end

    test "reports all tools missing when none available" do
      status = %{available: [], missing: [{"gh", :not_found}]}
      message = CLITools.format_status_message(status)
      assert message =~ "No CLI tools available"
      assert message =~ "gh"
    end

    test "reports partial availability correctly" do
      status = %{
        available: [{"linear", "/usr/bin/linear"}],
        missing: [{"gh", :not_found}]
      }

      message = CLITools.format_status_message(status)
      assert message =~ "Some CLI tools missing"
      assert message =~ "linear"
      assert message =~ "gh"
    end
  end

  describe "run_if_available/3" do
    test "runs command when tool exists" do
      result = CLITools.run_if_available("echo", ["hello"], timeout: 5_000)
      assert {:ok, "hello\n"} = result
    end

    test "returns error when tool doesn't exist" do
      result =
        CLITools.run_if_available("nonexistent_cmd_xyz", ["arg"],
          friendly_name: "My Tool",
          timeout: 5_000
        )

      assert {:error, {:tool_not_available, message}} = result
      assert message =~ "My Tool"
      assert message =~ "not found"
    end
  end

  describe "run_json_if_available/3" do
    test "returns error when tool doesn't exist" do
      result =
        CLITools.run_json_if_available("nonexistent_cmd_xyz", ["arg"],
          friendly_name: "JSON Tool",
          timeout: 5_000
        )

      assert {:error, {:tool_not_available, message}} = result
      assert message =~ "JSON Tool"
    end
  end

  describe "ensure_cache_table/0" do
    test "creates ETS table if it doesn't exist" do
      # Table should already exist from setup, but calling again should be safe
      CLITools.ensure_cache_table()

      # Should be able to insert and lookup
      :ets.insert(:cli_tools_cache, {:test_key, :test_value, 99_999_999_999})
      assert [{:test_key, :test_value, _}] = :ets.lookup(:cli_tools_cache, :test_key)
    end
  end
end
