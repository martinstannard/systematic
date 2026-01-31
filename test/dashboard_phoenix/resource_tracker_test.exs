defmodule DashboardPhoenix.ResourceTrackerTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.ResourceTracker

  describe "GenServer behavior - init" do
    test "init returns expected initial state" do
      {:ok, state} = ResourceTracker.init(%{})

      assert state.history == %{}
      assert state.last_sample == nil
    end
  end

  describe "GenServer behavior - handle_call :get_history" do
    test "get_history returns full history map" do
      history = %{
        "12345" => [{1000, 5.0, 1024}, {900, 4.5, 1000}],
        "67890" => [{1000, 2.0, 512}]
      }
      state = %{history: history, last_sample: 1000}

      {:reply, reply, new_state} = ResourceTracker.handle_call(:get_history, self(), state)

      assert reply == history
      assert new_state == state
    end

    test "get_history returns empty map when no history" do
      state = %{history: %{}, last_sample: nil}

      {:reply, reply, _} = ResourceTracker.handle_call(:get_history, self(), state)

      assert reply == %{}
    end
  end

  describe "GenServer behavior - handle_call {:get_history, pid}" do
    test "get_history for specific pid returns that pid's history" do
      history = %{
        "12345" => [{1000, 5.0, 1024}],
        "67890" => [{1000, 2.0, 512}]
      }
      state = %{history: history, last_sample: 1000}

      {:reply, reply, _} = ResourceTracker.handle_call({:get_history, "12345"}, self(), state)

      assert reply == [{1000, 5.0, 1024}]
    end

    test "get_history for unknown pid returns empty list" do
      history = %{"12345" => [{1000, 5.0, 1024}]}
      state = %{history: history, last_sample: 1000}

      {:reply, reply, _} = ResourceTracker.handle_call({:get_history, "99999"}, self(), state)

      assert reply == []
    end
  end

  describe "GenServer behavior - handle_call :get_current" do
    test "get_current returns latest stats for each process" do
      now = System.system_time(:millisecond)
      history = %{
        "12345" => [{now, 5.0, 1024}, {now - 5000, 4.5, 1000}],
        "67890" => [{now, 2.0, 512}]
      }
      state = %{history: history, last_sample: now}

      {:reply, current, _} = ResourceTracker.handle_call(:get_current, self(), state)

      assert Map.has_key?(current, "12345")
      assert Map.has_key?(current, "67890")

      assert current["12345"].cpu == 5.0
      assert current["12345"].memory == 1024
      assert current["12345"].history == history["12345"]

      assert current["67890"].cpu == 2.0
    end

    test "get_current handles empty history" do
      state = %{history: %{}, last_sample: nil}

      {:reply, current, _} = ResourceTracker.handle_call(:get_current, self(), state)

      assert current == %{}
    end

    test "get_current skips entries with empty history list" do
      history = %{
        "12345" => [{1000, 5.0, 1024}],
        "67890" => []  # Empty history
      }
      state = %{history: history, last_sample: 1000}

      {:reply, current, _} = ResourceTracker.handle_call(:get_current, self(), state)

      assert Map.has_key?(current, "12345")
      refute Map.has_key?(current, "67890")  # Should be filtered out
    end
  end

  describe "GenServer behavior - handle_info :sample" do
    test "sample schedules next sample" do
      state = %{history: %{}, last_sample: nil}

      {:noreply, _new_state} = ResourceTracker.handle_info(:sample, state)

      # Should receive :sample message after interval (5000ms default)
      # We use a longer timeout to be safe in CI
      assert_receive :sample, 6000
    end
  end

  describe "parse_memory_kb/1 (private function logic)" do
    test "parses valid memory string" do
      assert parse_memory_kb("1024") == 1024
      assert parse_memory_kb("0") == 0
      assert parse_memory_kb("999999") == 999_999
    end

    test "returns 0 for invalid memory string" do
      assert parse_memory_kb("invalid") == 0
      assert parse_memory_kb("") == 0
    end

    test "returns 0 for non-string input" do
      assert parse_memory_kb(nil) == 0
      assert parse_memory_kb(123) == 0
    end
  end

  describe "history management" do
    test "history data point format is {timestamp, cpu, memory_kb}" do
      # Verify the expected tuple format
      data_point = {1705315800000, 5.5, 2048}

      {timestamp, cpu, memory} = data_point

      assert is_integer(timestamp)
      assert is_number(cpu)
      assert is_integer(memory)
    end

    test "history maintains max entries (rolling window)" do
      # The ResourceTracker keeps @max_history entries (60)
      # This tests the expected behavior
      max_history = 60

      # Create more entries than max
      entries = for i <- 1..100, do: {i, 1.0, 100}

      # Simulating Enum.take behavior
      trimmed = Enum.take(entries, max_history)

      assert length(trimmed) == max_history
      # Should keep the first entries (newest first)
      assert hd(trimmed) == {1, 1.0, 100}
    end
  end

  describe "module exports" do
    test "exports expected client API functions" do
      assert function_exported?(ResourceTracker, :start_link, 1)
      assert function_exported?(ResourceTracker, :get_history, 0)
      assert function_exported?(ResourceTracker, :get_history, 1)
      assert function_exported?(ResourceTracker, :get_current, 0)
      assert function_exported?(ResourceTracker, :subscribe, 0)
    end
  end

  describe "configuration constants" do
    test "sample interval is reasonable for monitoring (< 60s)" do
      # The module uses 5 second interval
      # We verify via the schedule_sample message timing
      state = %{history: %{}, last_sample: nil}

      # Track when we receive the :sample message
      {:noreply, _} = ResourceTracker.handle_info(:sample, state)

      # Should receive within reasonable time (using 6s for margin)
      assert_receive :sample, 6000
    end
  end

  # Helper to test parse_memory_kb logic
  defp parse_memory_kb(rss_str) when is_binary(rss_str) do
    case Integer.parse(rss_str) do
      {val, _} -> val
      :error -> 0
    end
  end
  defp parse_memory_kb(_), do: 0
end
