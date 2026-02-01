defmodule DashboardPhoenix.AgentActivityMonitor.ConfigTest do
  use ExUnit.Case, async: true

  # Test the portable Config module directly
  alias AgentActivityMonitor.Config

  describe "struct defaults" do
    test "has sensible defaults" do
      config = %Config{}
      
      assert config.sessions_dir == nil
      assert config.persistence_file == "agent_activity_state.json"
      assert config.pubsub == nil
      assert config.task_supervisor == nil
      assert config.poll_interval_ms == 5_000
      assert config.cache_cleanup_interval_ms == 300_000
      assert config.gc_interval_ms == 300_000
      assert config.cli_timeout_ms == 10_000
      assert config.max_cache_entries == 1000
      assert config.max_recent_actions == 10
      assert config.file_retry_attempts == 3
      assert config.file_retry_delay_ms == 100
      assert config.save_state == nil
      assert config.load_state == nil
      # Default changed to false in portable version
      assert config.monitor_processes? == false
      assert config.name == nil
    end
  end

  describe "DashboardPhoenix.AgentActivityMonitor.dashboard_config/0" do
    test "creates config with DashboardPhoenix integration" do
      config = DashboardPhoenix.AgentActivityMonitor.dashboard_config()
      
      assert config.sessions_dir != nil
      assert config.pubsub == {DashboardPhoenix.PubSub, "agent_activity"}
      assert config.task_supervisor == DashboardPhoenix.TaskSupervisor
      assert config.name == DashboardPhoenix.AgentActivityMonitor
      assert is_function(config.save_state, 2)
      assert is_function(config.load_state, 2)
      # Dashboard config enables process monitoring
      assert config.monitor_processes? == true
    end
  end

  describe "minimal/1" do
    test "creates minimal config with just sessions_dir" do
      config = Config.minimal("/my/sessions")
      
      assert config.sessions_dir == "/my/sessions"
      assert config.pubsub == nil
      assert config.task_supervisor == nil
      assert config.save_state == nil
      assert config.load_state == nil
      assert config.monitor_processes? == false
      assert config.name == nil
    end
  end

  describe "new/2" do
    test "creates config with options merged into minimal defaults" do
      config = Config.new("/my/sessions", poll_interval_ms: 10_000, name: :my_monitor)
      
      assert config.sessions_dir == "/my/sessions"
      assert config.poll_interval_ms == 10_000
      assert config.name == :my_monitor
      # Other defaults preserved
      assert config.pubsub == nil
    end
  end

  describe "validate/1" do
    test "returns error for nil sessions_dir" do
      config = %Config{sessions_dir: nil}
      assert {:error, "sessions_dir is required"} = Config.validate(config)
    end

    test "returns ok for valid config" do
      config = %Config{sessions_dir: "/some/path"}
      assert {:ok, ^config} = Config.validate(config)
    end

    test "returns error for non-Config struct" do
      assert {:error, "config must be a Config struct"} = Config.validate(%{sessions_dir: "/path"})
    end
  end

  describe "backward compatibility" do
    test "deprecated Config module delegates to portable module" do
      # The DashboardPhoenix.AgentActivityMonitor.Config module should delegate
      config = DashboardPhoenix.AgentActivityMonitor.Config.minimal("/path/to/sessions")
      
      assert %Config{} = config
      assert config.sessions_dir == "/path/to/sessions"
    end
  end
end
