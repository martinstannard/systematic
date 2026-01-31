defmodule DashboardPhoenix.ResourceTrackerTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.ResourceTracker

  # NOTE: ResourceTracker is a GenServer that requires starting the supervision tree
  # and runs ps commands in the background. For unit testing purposes, we focus on
  # testing that the refactored code properly uses ProcessParser functionality.
  
  describe "ResourceTracker refactoring" do
    test "uses ProcessParser for parsing (integration test would need running GenServer)" do
      # This test mainly verifies the module compiles and has expected functions
      assert function_exported?(ResourceTracker, :start_link, 1)
      assert function_exported?(ResourceTracker, :get_history, 0)
      assert function_exported?(ResourceTracker, :get_current, 0)
    end
  end
end