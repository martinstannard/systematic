defmodule DashboardPhoenix.CLICacheTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.CLICache

  setup do
    # Clear cache before each test
    CLICache.clear()
    :ok
  end

  describe "get_or_fetch/3" do
    test "caches successful results" do
      call_count = :counters.new(1, [:atomics])
      
      fetch_fn = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, "result"}
      end
      
      # First call should execute the function
      assert {:ok, "result"} = CLICache.get_or_fetch("test_key", 60_000, fetch_fn)
      assert :counters.get(call_count, 1) == 1
      
      # Second call should return cached value
      assert {:ok, "result"} = CLICache.get_or_fetch("test_key", 60_000, fetch_fn)
      assert :counters.get(call_count, 1) == 1  # Still 1, not called again
    end

    test "does not cache errors" do
      call_count = :counters.new(1, [:atomics])
      
      fetch_fn = fn ->
        :counters.add(call_count, 1, 1)
        {:error, :some_error}
      end
      
      # First call returns error
      assert {:error, :some_error} = CLICache.get_or_fetch("error_key", 60_000, fetch_fn)
      assert :counters.get(call_count, 1) == 1
      
      # Second call should also execute the function (no caching of errors)
      assert {:error, :some_error} = CLICache.get_or_fetch("error_key", 60_000, fetch_fn)
      assert :counters.get(call_count, 1) == 2
    end

    test "expires entries after TTL" do
      call_count = :counters.new(1, [:atomics])
      
      fetch_fn = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, "result"}
      end
      
      # Cache with very short TTL (1ms)
      assert {:ok, "result"} = CLICache.get_or_fetch("ttl_key", 1, fetch_fn)
      assert :counters.get(call_count, 1) == 1
      
      # Wait for TTL to expire
      Process.sleep(10)
      
      # Should call function again
      assert {:ok, "result"} = CLICache.get_or_fetch("ttl_key", 1, fetch_fn)
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "invalidate/1" do
    test "removes specific cache entry" do
      call_count = :counters.new(1, [:atomics])
      
      fetch_fn = fn ->
        :counters.add(call_count, 1, 1)
        {:ok, "result"}
      end
      
      # Cache the value
      assert {:ok, "result"} = CLICache.get_or_fetch("invalidate_key", 60_000, fetch_fn)
      assert :counters.get(call_count, 1) == 1
      
      # Invalidate it
      CLICache.invalidate("invalidate_key")
      
      # Should call function again
      assert {:ok, "result"} = CLICache.get_or_fetch("invalidate_key", 60_000, fetch_fn)
      assert :counters.get(call_count, 1) == 2
    end
  end

  describe "invalidate_prefix/1" do
    test "removes all entries with prefix" do
      CLICache.get_or_fetch("gh:pr:list:repo1", 60_000, fn -> {:ok, "repo1"} end)
      CLICache.get_or_fetch("gh:pr:list:repo2", 60_000, fn -> {:ok, "repo2"} end)
      CLICache.get_or_fetch("linear:issues:Todo", 60_000, fn -> {:ok, "todo"} end)
      
      # Should have 3 entries
      stats = CLICache.stats()
      assert stats.valid_entries == 3
      
      # Invalidate all gh: entries
      count = CLICache.invalidate_prefix("gh:")
      assert count == 2
      
      # Should have 1 entry left
      stats = CLICache.stats()
      assert stats.valid_entries == 1
    end
  end

  describe "stats/0" do
    test "returns cache statistics" do
      CLICache.get_or_fetch("stats_key1", 60_000, fn -> {:ok, "value1"} end)
      CLICache.get_or_fetch("stats_key2", 60_000, fn -> {:ok, "value2"} end)
      
      stats = CLICache.stats()
      
      assert stats.total_entries == 2
      assert stats.valid_entries == 2
      assert stats.expired_entries == 0
      assert is_integer(stats.memory_bytes)
    end
  end

  describe "clear/0" do
    test "removes all cache entries" do
      CLICache.get_or_fetch("clear_key1", 60_000, fn -> {:ok, "value1"} end)
      CLICache.get_or_fetch("clear_key2", 60_000, fn -> {:ok, "value2"} end)
      
      assert CLICache.stats().valid_entries == 2
      
      CLICache.clear()
      
      assert CLICache.stats().valid_entries == 0
    end
  end
end
