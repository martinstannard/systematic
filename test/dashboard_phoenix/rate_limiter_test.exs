defmodule DashboardPhoenix.RateLimiterTest do
  use ExUnit.Case, async: false
  
  alias DashboardPhoenix.RateLimiter

  setup do
    # Ensure RateLimiter is started
    case GenServer.whereis(RateLimiter) do
      nil ->
        {:ok, _pid} = RateLimiter.start_link([])
      _pid ->
        :ok
    end
    
    # Reset rate limiter before each test for proper test isolation
    RateLimiter.reset()
    
    on_exit(fn ->
      # Reset after test
      case GenServer.whereis(RateLimiter) do
        nil -> :ok
        _pid -> RateLimiter.reset()
      end
    end)
    
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
      # Use actual commands with different buckets to test independence
      # "gh" has 30 tokens, "linear" has 40 tokens - these are separate buckets
      gh_cmd = "gh"
      linear_cmd = "linear"
      
      # Exhaust gh's tokens (30)
      for _ <- 1..30 do
        assert RateLimiter.acquire(gh_cmd) == :ok
      end
      
      # gh should be rate limited now
      assert RateLimiter.acquire(gh_cmd) == {:error, :rate_limited}
      
      # linear should still work (different bucket)
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
    @tag :slow
    test "tokens are refilled over time" do
      # Use "gh" command which has 30 req/min (0.5 tokens/sec)
      # After 3 seconds we should have at least 1 token
      test_cmd = "gh"
      
      # Reset to ensure we start with full bucket
      RateLimiter.reset()
      
      # Exhaust all 30 tokens for gh
      for _ <- 1..30 do
        assert RateLimiter.acquire(test_cmd) == :ok
      end
      
      # Should be rate limited now
      assert RateLimiter.acquire(test_cmd) == {:error, :rate_limited}
      
      # Wait for refill (30 req/min = 0.5 tokens/sec, need 3s for 1.5 tokens)
      Process.sleep(3_100)
      
      # Should be able to acquire again (at least 1 token refilled)
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