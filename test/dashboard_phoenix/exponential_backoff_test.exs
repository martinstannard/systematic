defmodule DashboardPhoenix.ExponentialBackoffTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.ExponentialBackoff

  describe "retryable error detection" do
    test "identifies retryable errors" do
      assert ExponentialBackoff.retryable?(:timeout)
      assert ExponentialBackoff.retryable?({:exit, 1, "network error"})
      assert ExponentialBackoff.retryable?({:exit, 2, "API rate limit exceeded"})
      assert ExponentialBackoff.retryable?({:exit, 1, "502 Bad Gateway"})
      assert ExponentialBackoff.retryable?({:exit, 1, "temporarily unavailable"})
      assert ExponentialBackoff.retryable?({:exit, 1, "abuse detection"})
    end

    test "identifies non-retryable errors" do
      refute ExponentialBackoff.retryable?({:exit, 1, "authentication failed"})
      refute ExponentialBackoff.retryable?({:exit, 1, "permission denied"})
      refute ExponentialBackoff.retryable?({:exit, 1, "not found"})
      refute ExponentialBackoff.retryable?({:json_decode, "invalid json"})
    end
  end

  describe "retry logic" do
    test "succeeds on first attempt" do
      fun = fn -> {:ok, "success"} end

      result = ExponentialBackoff.retry(fun)
      assert result == {:ok, "success"}
    end

    test "retries failing operation until success" do
      # Create a function that fails twice then succeeds
      agent = Agent.start_link(fn -> 0 end)
      {:ok, agent} = agent

      fun = fn ->
        attempt = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

        if attempt >= 3 do
          {:ok, "success on attempt #{attempt}"}
        else
          {:error, "failure on attempt #{attempt}"}
        end
      end

      result = ExponentialBackoff.retry(fun, max_attempts: 5, initial_delay_ms: 10)
      assert result == {:ok, "success on attempt 3"}

      Agent.stop(agent)
    end

    test "fails after max attempts" do
      fun = fn -> {:error, "always fails"} end

      result = ExponentialBackoff.retry(fun, max_attempts: 3, initial_delay_ms: 10)
      assert result == {:error, "always fails"}
    end

    test "respects custom retry options" do
      # Track how many times the function is called
      agent = Agent.start_link(fn -> 0 end)
      {:ok, agent} = agent

      fun = fn ->
        Agent.update(agent, &(&1 + 1))
        {:error, "always fails"}
      end

      ExponentialBackoff.retry(fun, max_attempts: 2, initial_delay_ms: 10)

      attempts = Agent.get(agent, & &1)
      assert attempts == 2

      Agent.stop(agent)
    end
  end

  describe "retry_if_retryable" do
    test "retries retryable errors" do
      agent = Agent.start_link(fn -> 0 end)
      {:ok, agent} = agent

      fun = fn ->
        attempt = Agent.get_and_update(agent, fn count -> {count + 1, count + 1} end)

        if attempt >= 2 do
          {:ok, "success"}
        else
          # Retryable error
          {:error, :timeout}
        end
      end

      result = ExponentialBackoff.retry_if_retryable(fun, max_attempts: 3, initial_delay_ms: 10)
      assert result == {:ok, "success"}

      Agent.stop(agent)
    end

    test "does not retry non-retryable errors" do
      agent = Agent.start_link(fn -> 0 end)
      {:ok, agent} = agent

      fun = fn ->
        Agent.update(agent, &(&1 + 1))
        # Non-retryable error
        {:error, "permission denied"}
      end

      result = ExponentialBackoff.retry_if_retryable(fun, max_attempts: 3, initial_delay_ms: 10)
      assert result == {:error, "permission denied"}

      # Should only have been called once
      attempts = Agent.get(agent, & &1)
      assert attempts == 1

      Agent.stop(agent)
    end

    test "returns success immediately" do
      fun = fn -> {:ok, "immediate success"} end

      result = ExponentialBackoff.retry_if_retryable(fun)
      assert result == {:ok, "immediate success"}
    end
  end

  describe "delay calculation" do
    test "increases delay with each attempt" do
      # We'll test this indirectly by timing the retries
      agent = Agent.start_link(fn -> 0 end)
      {:ok, agent} = agent

      fun = fn ->
        Agent.update(agent, &(&1 + 1))
        # Always fail with retryable error
        {:error, :timeout}
      end

      start_time = System.monotonic_time(:millisecond)
      ExponentialBackoff.retry(fun, max_attempts: 3, initial_delay_ms: 100, jitter: false)
      end_time = System.monotonic_time(:millisecond)

      # Total delay should be approximately 100ms + 200ms = 300ms
      # (first failure waits 100ms, second failure waits 200ms)
      total_time = end_time - start_time
      # Allow some wiggle room
      assert total_time >= 280

      Agent.stop(agent)
    end
  end
end
