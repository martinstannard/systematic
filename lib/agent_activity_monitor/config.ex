defmodule AgentActivityMonitor.Config do
  @moduledoc """
  Configuration struct for AgentActivityMonitor.

  This module is fully portable and has no framework-specific dependencies.
  All options have sensible defaults that work standalone.

  ## Example

      config = %AgentActivityMonitor.Config{
        sessions_dir: "/path/to/sessions",
        pubsub: {MyApp.PubSub, "agent_activity"},
        poll_interval_ms: 10_000
      }
      
      AgentActivityMonitor.Server.start_link(config: config)

  ## Minimal Configuration

  For testing or simple use cases:

      config = AgentActivityMonitor.Config.minimal("/path/to/sessions")
      {:ok, pid} = AgentActivityMonitor.Server.start_link(config: config)
  """

  @type pubsub_config :: {module(), String.t()} | nil
  @type task_supervisor :: atom() | nil
  @type persistence_callback :: (String.t(), map() -> :ok | {:error, term()}) | nil
  @type load_callback :: (String.t(), map() -> map()) | nil
  @type gc_callback :: (module() -> :ok) | nil
  @type process_finder_callback :: (pos_integer() -> map()) | nil

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

          # Optional callbacks for extensibility
          gc_trigger: gc_callback(),
          find_processes: process_finder_callback(),

          # Custom name for the GenServer (optional)
          name: GenServer.name() | nil
        }

  # Exclude non-serializable fields from JSON encoding
  @derive {Jason.Encoder,
           except: [
             :pubsub,
             :task_supervisor,
             :save_state,
             :load_state,
             :gc_trigger,
             :find_processes
           ]}

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
            monitor_processes?: false,
            gc_trigger: nil,
            find_processes: nil,
            name: nil

  @doc """
  Creates a minimal Config suitable for testing or standalone use.

  No external dependencies - just basic file monitoring.

  ## Example

      config = AgentActivityMonitor.Config.minimal("/tmp/sessions")
      {:ok, pid} = AgentActivityMonitor.Server.start_link(config: config)
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
      gc_trigger: nil,
      find_processes: nil,
      name: nil
    }
  end

  @doc """
  Creates a Config with custom options merged into minimal defaults.

  ## Example

      config = AgentActivityMonitor.Config.new("/tmp/sessions",
        poll_interval_ms: 10_000,
        name: MyApp.AgentMonitor
      )
  """
  @spec new(String.t(), keyword()) :: t()
  def new(sessions_dir, opts \\ []) do
    base = minimal(sessions_dir)
    struct(base, opts)
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
