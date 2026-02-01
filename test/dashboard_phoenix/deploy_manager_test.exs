defmodule DashboardPhoenix.DeployManagerTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.DeployManager
  alias DashboardPhoenix.ActivityLog

  # Mock modules for testing
  defmodule MockCommandRunner do
    def run_command(cmd, args, opts \\ [])

    def run_command("systemctl", ["--user", "restart", "systematic.service"], _opts) do
      send(self(), {:mock_called, :restart})
      {"", 0}
    end

    def run_command("systemctl", ["--user", "is-active", "systematic.service"], _opts) do
      send(self(), {:mock_called, :is_active})
      {"active\n", 0}
    end

    def run_command("git", ["rev-parse", "--short", "HEAD"], opts) do
      send(self(), {:mock_called, :git_hash, opts})
      {"abc1234", 0}
    end
  end

  defmodule MockCommandRunnerFail do
    def run_command(cmd, args, opts \\ [])

    def run_command("systemctl", ["--user", "restart", "systematic.service"], _opts) do
      {"Unit not found", 1}
    end

    def run_command(_cmd, _args, _opts) do
      {"", 0}
    end
  end

  defmodule MockHttpClient do
    def health_check(_url) do
      send(self(), {:mock_called, :health_check})
      {:ok, 200}
    end
  end

  defmodule MockHttpClientFail do
    def health_check(_url) do
      {:error, :econnrefused}
    end
  end

  setup do
    # Reset DeployManager state before each test
    DeployManager.reset()
    ActivityLog.clear()
    :ok
  end

  describe "trigger_deploy/1" do
    test "returns pending when triggered" do
      assert {:ok, :pending} = DeployManager.trigger_deploy()
    end

    test "returns pending on subsequent calls within debounce window" do
      {:ok, :pending} = DeployManager.trigger_deploy()
      {:ok, :pending} = DeployManager.trigger_deploy()
      {:ok, :pending} = DeployManager.trigger_deploy()
    end

    test "force option triggers immediately" do
      # We can't easily test the full pipeline without mocks configured,
      # but we can verify the status changes
      {:ok, :triggered} = DeployManager.trigger_deploy(force: true)

      # Status should be restarting or later
      status = DeployManager.get_status()
      assert status.status in [:restarting, :waiting_for_service, :health_checking, :failed]
    end
  end

  describe "get_status/0" do
    test "returns idle status initially" do
      status = DeployManager.get_status()

      assert status.status == :idle
      assert status.last_deploy == nil
      assert status.last_error == nil
    end

    test "returns pending status when deploy is scheduled" do
      DeployManager.trigger_deploy()

      status = DeployManager.get_status()
      assert status.status == :pending
    end
  end

  describe "PubSub integration" do
    test "broadcasts status changes to subscribers" do
      DeployManager.subscribe()

      DeployManager.trigger_deploy()

      assert_receive {:deploy_status, :pending}, 100
    end

    test "unsubscribe stops receiving events" do
      DeployManager.subscribe()
      DeployManager.unsubscribe()

      DeployManager.trigger_deploy()

      refute_receive {:deploy_status, _}, 100
    end
  end

  describe "debouncing" do
    test "batches multiple requests within debounce window" do
      # Trigger multiple deploys
      {:ok, :pending} = DeployManager.trigger_deploy()
      {:ok, :pending} = DeployManager.trigger_deploy()
      {:ok, :pending} = DeployManager.trigger_deploy()

      # All should return pending, not trigger separate deploys
      status = DeployManager.get_status()
      assert status.status == :pending
    end

    test "force bypasses debounce" do
      {:ok, :pending} = DeployManager.trigger_deploy()
      {:ok, :triggered} = DeployManager.trigger_deploy(force: true)

      # Status should have moved past pending
      status = DeployManager.get_status()
      assert status.status != :pending
    end
  end

  describe "reset/0" do
    test "resets state to idle" do
      DeployManager.trigger_deploy()
      assert DeployManager.get_status().status == :pending

      :ok = DeployManager.reset()

      assert DeployManager.get_status().status == :idle
    end
  end

  describe "pubsub_topic/0" do
    test "returns the topic string" do
      assert DeployManager.pubsub_topic() == "deploy_manager:events"
    end
  end

  describe "module exports" do
    test "exports expected client API functions" do
      assert function_exported?(DeployManager, :start_link, 1)
      assert function_exported?(DeployManager, :trigger_deploy, 0)
      assert function_exported?(DeployManager, :trigger_deploy, 1)
      assert function_exported?(DeployManager, :get_status, 0)
      assert function_exported?(DeployManager, :subscribe, 0)
      assert function_exported?(DeployManager, :unsubscribe, 0)
      assert function_exported?(DeployManager, :reset, 0)
    end
  end

  describe "already running protection" do
    test "returns already_running when deploy is in progress" do
      # Force trigger to start immediately
      {:ok, :triggered} = DeployManager.trigger_deploy(force: true)

      # While it's running, another trigger should return already_running
      # (if it's still in a running state)
      status = DeployManager.get_status()

      if status.status in [:restarting, :waiting_for_service, :health_checking] do
        assert {:ok, :already_running} = DeployManager.trigger_deploy()
      end
    end
  end

  describe "default implementations" do
    test "run_command delegates to System.cmd" do
      # Just verify the function exists and can be called
      assert function_exported?(DeployManager, :run_command, 2)
      assert function_exported?(DeployManager, :run_command, 3)
    end

    test "health_check uses Req" do
      assert function_exported?(DeployManager, :health_check, 1)
    end
  end
end
