defmodule DashboardPhoenix.OpenCodeServer do
  @moduledoc """
  GenServer that manages an OpenCode ACP server process.
  
  The ACP (Agent Client Protocol) server allows external clients to communicate
  with OpenCode via JSON-RPC over stdio (subprocess) or HTTP (server mode).
  
  This GenServer:
  - Starts the OpenCode ACP server on a configured port
  - Monitors the process health
  - Provides status information
  - Handles cleanup on shutdown
  """
  use GenServer
  require Logger

  alias DashboardPhoenix.Paths

  @default_port 9100
  @pubsub DashboardPhoenix.PubSub
  @topic "opencode_server"

  defp opencode_bin, do: Paths.opencode_bin()
  defp default_cwd, do: Paths.default_work_dir()

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start the OpenCode ACP server if not already running.
  """
  def start_server(cwd \\ nil) do
    GenServer.call(__MODULE__, {:start_server, cwd || default_cwd()}, 30_000)
  end

  @doc """
  Stop the OpenCode ACP server.
  """
  def stop_server do
    GenServer.call(__MODULE__, :stop_server)
  end

  @doc """
  Get current server status.
  Returns a map with :running, :port, :cwd, :pid, :started_at
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Check if the server is running.
  """
  def running? do
    status().running
  end

  @doc """
  Get the server port if running.
  """
  def port do
    status = status()
    if status.running, do: status.port, else: nil
  end

  @doc """
  Subscribe to server status changes.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    
    state = %{
      port: port,
      running: false,
      os_pid: nil,
      port_ref: nil,
      cwd: nil,
      started_at: nil,
      output_buffer: ""
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call({:start_server, _cwd}, _from, %{running: true} = state) do
    Logger.info("[OpenCodeServer] Server already running on port #{state.port}")
    {:reply, {:ok, state.port}, state}
  end

  @impl true
  def handle_call({:start_server, cwd}, _from, state) do
    Logger.info("[OpenCodeServer] Starting server on port #{state.port} with cwd: #{cwd}")
    
    # Build the command
    # Bind to 0.0.0.0 to allow access from other machines (e.g., via Tailscale)
    args = ["acp", "--port", "#{state.port}", "--hostname", "0.0.0.0", "--cwd", cwd, "--print-logs"]
    
    # Start the port with proper options
    port_opts = [
      :binary,
      :exit_status,
      :use_stdio,
      :stderr_to_stdout,
      {:args, args},
      {:cd, cwd}
    ]
    
    try do
      port_ref = Port.open({:spawn_executable, opencode_bin()}, port_opts)
      {:os_pid, os_pid} = Port.info(port_ref, :os_pid)
      
      Logger.info("[OpenCodeServer] Started with OS PID: #{os_pid}")
      
      # Wait a moment for the server to initialize
      Process.sleep(2000)
      
      new_state = %{state |
        running: true,
        os_pid: os_pid,
        port_ref: port_ref,
        cwd: cwd,
        started_at: DateTime.utc_now()
      }
      
      broadcast_status(new_state)
      {:reply, {:ok, state.port}, new_state}
    rescue
      e ->
        Logger.error("[OpenCodeServer] Failed to start: #{inspect(e)}")
        {:reply, {:error, inspect(e)}, state}
    end
  end

  @impl true
  def handle_call(:stop_server, _from, %{running: false} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop_server, _from, state) do
    Logger.info("[OpenCodeServer] Stopping server (PID: #{state.os_pid})")
    
    if state.port_ref do
      Port.close(state.port_ref)
    end
    
    # Also kill the OS process to be sure
    if state.os_pid do
      System.cmd("kill", ["-9", "#{state.os_pid}"], stderr_to_stdout: true)
    end
    
    new_state = %{state |
      running: false,
      os_pid: nil,
      port_ref: nil,
      cwd: nil,
      started_at: nil
    }
    
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      running: state.running,
      port: state.port,
      cwd: state.cwd,
      pid: state.os_pid,
      started_at: state.started_at
    }
    {:reply, status, state}
  end

  # Handle port messages (stdout/stderr from the process)
  @impl true
  def handle_info({port_ref, {:data, data}}, %{port_ref: port_ref} = state) when is_port(port_ref) do
    # Log output from the OpenCode process
    Logger.debug("[OpenCodeServer] #{String.trim(data)}")
    {:noreply, %{state | output_buffer: state.output_buffer <> data}}
  end

  # Handle process exit
  @impl true
  def handle_info({port_ref, {:exit_status, status}}, %{port_ref: port_ref} = state) when is_port(port_ref) do
    Logger.warning("[OpenCodeServer] Process exited with status: #{status}")
    
    new_state = %{state |
      running: false,
      os_pid: nil,
      port_ref: nil
    }
    
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[OpenCodeServer] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port_ref: port_ref, os_pid: os_pid}) do
    Logger.info("[OpenCodeServer] Terminating, cleaning up...")
    
    if port_ref && Port.info(port_ref) do
      Port.close(port_ref)
    end
    
    if os_pid do
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end
    
    :ok
  end

  # Private functions

  defp broadcast_status(state) do
    status = %{
      running: state.running,
      port: state.port,
      cwd: state.cwd,
      pid: state.os_pid,
      started_at: state.started_at
    }
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:opencode_status, status})
  end
end
