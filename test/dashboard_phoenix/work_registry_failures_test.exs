defmodule DashboardPhoenix.WorkRegistryFailuresTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.WorkRegistry

  setup do
    # Wait for WorkRegistry to be ready
    :ok = ensure_work_registry_started()

    # Clean up any existing work entries
    for entry <- WorkRegistry.all() do
      WorkRegistry.remove(entry.id)
    end

    :ok
  end

  defp ensure_work_registry_started do
    case Process.whereis(WorkRegistry) do
      nil ->
        # Start it if not running
        {:ok, _pid} = WorkRegistry.start_link([])
        :ok

      _pid ->
        :ok
    end
  end

  describe "failed/0" do
    test "returns empty list when no failures" do
      assert WorkRegistry.failed() == []
    end

    test "returns failed entries" do
      # Register and fail a work entry
      {:ok, work_id} =
        WorkRegistry.register(%{
          agent_type: :claude,
          description: "Test task"
        })

      :ok = WorkRegistry.fail(work_id, "[connection_error] Server not reachable")

      failed = WorkRegistry.failed()
      assert length(failed) == 1
      assert hd(failed).id == work_id
      assert hd(failed).status == :failed
      assert hd(failed).failure_reason =~ "connection_error"
    end

    test "sorts failures by failed_at descending" do
      # Create multiple failures
      {:ok, id1} = WorkRegistry.register(%{agent_type: :claude, description: "Task 1"})
      :ok = WorkRegistry.fail(id1, "Error 1")

      # Ensure different timestamps
      Process.sleep(10)

      {:ok, id2} = WorkRegistry.register(%{agent_type: :opencode, description: "Task 2"})
      :ok = WorkRegistry.fail(id2, "Error 2")

      failed = WorkRegistry.failed()
      assert length(failed) == 2
      # Most recent should be first
      assert hd(failed).id == id2
    end
  end

  describe "recent_failures/1" do
    test "returns limited number of failures" do
      # Create 7 failures
      for i <- 1..7 do
        {:ok, id} = WorkRegistry.register(%{agent_type: :claude, description: "Task #{i}"})
        :ok = WorkRegistry.fail(id, "Error #{i}")
        Process.sleep(5)
      end

      # Default limit is 5
      recent = WorkRegistry.recent_failures()
      assert length(recent) == 5

      # Custom limit
      recent3 = WorkRegistry.recent_failures(3)
      assert length(recent3) == 3
    end

    test "returns all failures if less than limit" do
      {:ok, id} = WorkRegistry.register(%{agent_type: :claude, description: "Single task"})
      :ok = WorkRegistry.fail(id, "Single error")

      recent = WorkRegistry.recent_failures(10)
      assert length(recent) == 1
    end
  end
end
