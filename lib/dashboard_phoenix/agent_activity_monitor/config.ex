defmodule DashboardPhoenix.AgentActivityMonitor.Config do
  @moduledoc """
  Configuration struct for AgentActivityMonitor.
  
  Allows customizing the monitor behavior without hardcoding dependencies.
  All options have sensible defaults that work with the DashboardPhoenix application.
  
  ## Example
  
      config = %Config{
        sessions_dir: "/custom/path/to/sessions",
        pubsub: {MyApp.PubSub, "agent_activity"},
        poll_interval_ms: 10_000
      }
      
      AgentActivityMonitor.start_link(config: config)
  """

  @type pubsub_config :: {module(), String.t()} | nil
  @type task_supervisor :: atom() | nil
  @type persistence_callback :: (String.t(), map() -> :ok | {:error, term()}) | nil
  @type load_callback :: (String.t(), map() -> map()) | nil

  @type t :: %__MODULE__{
          # Core paths
          sessions_dir: String.t() | nil,
          persistence_file: String.t(),
          
          # Broadcasting
          pubsub: pubsub_config(),
          
          # Supervision
          task_supervisor: task_supervisor(),
          
          # Timing
          poll_interval_ms: pos_integer(),
          cache_cleanup_interval_ms: pos_integer(),
          gc_interval_ms: pos_integer(),
          cli_timeout_ms: pos_integer(),
          
          # Cache settings  
          max_cache_entries: pos_integer(),
          max_recent_actions: pos_integer(),
          file_retry_attempts: pos_integer(),
          file_retry_delay_ms: pos_integer(),
          
          # Persistence callbacks (optional)
          save_state: persistence_callback(),
          load_state: load_callback(),
          
          # Process monitoring (optional - can be disabled)
          monitor_processes?: boolean(),
          
          # Custom name for the GenServer (optional)
          name: GenServer.name() | nil
        }

  defstruct sessions_dir: nil,
            persistence_file: "agent_activity_state.json",
            pubsub: nil,
            task_supervisor: nil,
            poll_interval_ms: 5_000,
            cache_cleanup_interval_ms: 300_000,
            gc_interval_ms: 300_000,
            cli_timeout_ms: 10_000,
            max_cache_entries: 1000,
            max_recent_actions: 10,
            file_retry_attempts: 3,
            file_retry_delay_ms: 100,
            save_state: nil,
            load_state: nil,
            monitor_processes?: true,
            name: nil

  @doc """
  Creates a Config with DashboardPhoenix defaults.
  
  Uses standard DashboardPhoenix modules for paths, persistence, etc.
  """
  @spec dashboard_defaults() :: t()
  def dashboard_defaults do
    %__MODULE__{
      sessions_dir: DashboardPhoenix.Paths.openclaw_sessions_dir(),
      pubsub: {DashboardPhoenix.PubSub, "agent_activity"},
      task_supervisor: DashboardPhoenix.TaskSupervisor,
      save_state: &DashboardPhoenix.StatePersistence.save/2,
      load_state: &DashboardPhoenix.StatePersistence.load/2,
      name: DashboardPhoenix.AgentActivityMonitor
    }
  end

  @doc """
  Creates a minimal Config suitable for testing or standalone use.
  
  No external dependencies - just basic file monitoring.
  """
  @spec minimal(String.t()) :: t()
  def minimal(sessions_dir) do
    %__MODULE__{
      sessions_dir: sessions_dir,
      pubsub: nil,
      task_supervisor: nil,
      save_state: nil,
      load_state: nil,
      monitor_processes?: false,
      name: nil
    }
  end

  @doc """
  Validates a config, returning {:ok, config} or {:error, reason}.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{sessions_dir: nil}) do
    {:error, "sessions_dir is required"}
  end

  def validate(%__MODULE__{} = config) do
    {:ok, config}
  end

  def validate(_other) do
    {:error, "config must be a Config struct"}
  end
end
