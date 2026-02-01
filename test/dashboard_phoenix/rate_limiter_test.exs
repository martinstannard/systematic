defmodule DashboardPhoenix.RateLimiterTest do
  use ExUnit.Case, async: false
  
  alias DashboardPhoenix.RateLimiter

  setup do
    # For simplicity, just test against the global instance
    # In a real scenario, we'd want isolated instances, but this works for basic functionality testing
    :ok
  end

  describe "token acquisition" do
    test "allows requests within rate limit" do
      # Should be able to acquire multiple tokens initially
      # We'll test this with a less common command to avoid interference
      test_cmd = "test_cmd_#{:rand.uniform(10000)}"
      assert RateLimiter.acquire(test_cmd) == :ok
      assert RateLimiter.acquire(test_cmd) == :ok
      assert RateLimiter.acquire(test_cmd) == :ok
    end

    test "different commands have independent rate limits" do
      # Use unique command names to avoid test interference
      gh_cmd = "test_gh_#{:rand.uniform(10000)}"
      linear_cmd = "test_linear_#{:rand.uniform(10000)}"
      
      # Exhaust one command's tokens (using default 20 for unknown commands)
      for _ <- 1..20 do
        assert RateLimiter.acquire(gh_cmd) == :ok
      end
      
      # Should be rate limited now
      assert RateLimiter.acquire(gh_cmd) == {:error, :rate_limited}
      
      # Different command should still work
      assert RateLimiter.acquire(linear_cmd) == :ok
    end

    test "unknown commands use default rate limit" do
      # Use a unique command name to avoid interference
      test_cmd = "unknown_cmd_#{:rand.uniform(10000)}"
      
      # Exhaust default tokens (20)
      for _ <- 1..20 do
        assert RateLimiter.acquire(test_cmd) == :ok
      end
      
      # Next should fail
      assert RateLimiter.acquire(test_cmd) == {:error, :rate_limited}
    end
  end

  describe "token refill" do
    test "tokens are refilled over time" do
      # Use unique command to avoid interference
      test_cmd = "refill_test_#{:rand.uniform(10000)}"
      
      # Exhaust tokens (using default 20 for unknown commands)
      for _ <- 1..20 do
        assert RateLimiter.acquire(test_cmd) == :ok
      end
      
      # Should be rate limited
      assert RateLimiter.acquire(test_cmd) == {:error, :rate_limited}
      
      # Wait for refill (need to wait a bit for tokens to refill)
      Process.sleep(2_100)  # Just over 2 seconds
      
      # Should be able to acquire again
      assert RateLimiter.acquire(test_cmd) == :ok
    end
  end

  describe "state inspection" do
    test "get_state returns current bucket states" do
      state = RateLimiter.get_state()
      
      assert is_map(state.buckets)
      # Should have known command buckets
      assert Map.has_key?(state.buckets, "gh")
      assert Map.has_key?(state.buckets, "linear")
      assert Map.has_key?(state.buckets, :default)
      
      # Buckets should have expected structure
      gh_bucket = state.buckets["gh"]
      assert is_number(gh_bucket.tokens)
      assert gh_bucket.max_tokens == 30
    end
  end
end