defmodule DashboardPhoenix.OpenCodeServer do
  @moduledoc """
  GenServer that manages an OpenCode ACP server process with supervision.
  
  The ACP (Agent Client Protocol) server allows external clients to communicate
  with OpenCode via JSON-RPC over stdio (subprocess) or HTTP (server mode).
  
  This GenServer provides:
  - Automatic restart of crashed processes with exponential backoff
  - Periodic health checks via HTTP
  - Graceful shutdown (SIGTERM then SIGKILL)
  - Output buffer size limits to prevent memory leaks
  - Proper readiness probes instead of sleep-based startup
  - Circuit breaker for repeatedly failing processes
  """
  use GenServer
  require Logger

  alias DashboardPhoenix.Paths
  alias DashboardPhoenix.CommandRunner
  alias DashboardPhoenix.OpenCodeClient
  alias DashboardPhoenix.ActivityLog

  @default_port 9101
  @pubsub DashboardPhoenix.PubSub
  @topic "opencode_server"

  # Health check configuration
  @health_check_interval_ms 30_000  # Check every 30 seconds
  @health_check_timeout_ms 5_000    # Timeout for health check request

  # Readiness probe configuration
  @readiness_max_attempts 30        # Max attempts to check readiness
  @readiness_interval_ms 200        # Time between readiness checks

  # Output buffer configuration
  @max_output_buffer_size 100_000   # ~100KB max buffer size
  @output_rotation_size 50_000      # Keep last 50KB when rotating

  # Circuit breaker configuration
  @max_restarts 5                   # Max restarts within time window
  @restart_window_ms 300_000        # 5 minute window for restart counting
  @circuit_breaker_cooldown_ms 60_000  # Wait 1 minute before allowing restart after circuit opens

  # Restart backoff configuration
  @initial_restart_delay_ms 1_000   # 1 second initial delay
  @max_restart_delay_ms 30_000      # 30 second max delay
  @restart_backoff_factor 2.0

  # Graceful shutdown configuration
  @graceful_shutdown_timeout_ms 5_000  # Wait 5s for graceful shutdown

  # Session cleanup configuration
  @session_cleanup_interval_ms 900_000  # Run every 15 minutes
  @session_stale_threshold_ms 3_600_000  # 1 hour idle = stale

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
    GenServer.call(__MODULE__, {:start_server, cwd || default_cwd()}, 60_000)
  end

  @doc """
  Stop the OpenCode ACP server.
  """
  def stop_server do
    GenServer.call(__MODULE__, :stop_server, 30_000)
  end

  @doc """
  Get current server status.
  Returns a map with :running, :port, :cwd, :pid, :started_at, :health_status, :restart_count
  """
  def status do
    GenServer.call(__MODULE__, :status, 5_000)
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

  @doc """
  Reset the circuit breaker (allows manual recovery after repeated failures).
  """
  def reset_circuit_breaker do
    GenServer.call(__MODULE__, :reset_circuit_breaker)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)
    auto_start = Keyword.get(opts, :auto_start, true)
    
    state = %{
      # Configuration
      port: port,
      auto_restart: Keyword.get(opts, :auto_restart, true),
      auto_start: auto_start,
      
      # Process state
      running: false,
      os_pid: nil,
      port_ref: nil,
      cwd: nil,
      started_at: nil,
      
      # Health monitoring
      health_status: :unknown,
      last_health_check: nil,
      health_check_timer: nil,
      
      # Output buffering
      output_buffer: "",
      
      # Restart management
      restart_count: 0,
      restart_times: [],  # Timestamps of recent restarts
      consecutive_failures: 0,
      next_restart_delay_ms: @initial_restart_delay_ms,
      restart_timer: nil,
      
      # Circuit breaker
      circuit_state: :closed,  # :closed (normal), :open (failing too much), :half_open (testing)
      circuit_opened_at: nil,
      
      # Session cleanup
      cleanup_timer: nil
    }
    
    # Schedule periodic session cleanup
    cleanup_timer = schedule_session_cleanup()
    state = %{state | cleanup_timer: cleanup_timer}
    
    # Auto-start if enabled
    if auto_start do
      Logger.info("[OpenCodeServer] Auto-starting on boot...")
      send(self(), :auto_start)
    end
    
    {:ok, state}
  end
  
  @impl true
  def handle_info(:auto_start, state) do
    cwd = default_cwd()
    case do_start_server(cwd, state) do
      {:ok, new_state} ->
        Logger.info("[OpenCodeServer] Auto-start successful")
        {:noreply, new_state}
      {:error, reason, new_state} ->
        Logger.warning("[OpenCodeServer] Auto-start failed: #{inspect(reason)}, will retry on demand")
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:start_server, _cwd}, _from, %{running: true} = state) do
    Logger.info("[OpenCodeServer] Server already running on port #{state.port}")
    {:reply, {:ok, state.port}, state}
  end

  @impl true
  def handle_call({:start_server, cwd}, _from, state) do
    case check_circuit_breaker(state) do
      {:ok, updated_state} ->
        case do_start_server(cwd, updated_state) do
          {:ok, new_state} ->
            {:reply, {:ok, state.port}, new_state}
          {:error, reason, new_state} ->
            {:reply, {:error, reason}, new_state}
        end
      
      {:circuit_open, updated_state} ->
        {:reply, {:error, :circuit_breaker_open}, updated_state}
    end
  end

  @impl true
  def handle_call(:stop_server, _from, %{running: false} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop_server, _from, state) do
    new_state = do_stop_server(state, :manual)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      running: state.running,
      port: state.port,
      cwd: state.cwd,
      pid: state.os_pid,
      started_at: state.started_at,
      health_status: state.health_status,
      last_health_check: state.last_health_check,
      restart_count: state.restart_count,
      circuit_state: state.circuit_state,
      consecutive_failures: state.consecutive_failures
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call(:reset_circuit_breaker, _from, state) do
    Logger.info("[OpenCodeServer] Circuit breaker manually reset")
    new_state = %{state |
      circuit_state: :closed,
      circuit_opened_at: nil,
      consecutive_failures: 0,
      restart_times: [],
      next_restart_delay_ms: @initial_restart_delay_ms
    }
    {:reply, :ok, new_state}
  end

  # Handle port messages (stdout/stderr from the process)
  @impl true
  def handle_info({port_ref, {:data, data}}, %{port_ref: port_ref} = state) when is_port(port_ref) do
    Logger.debug("[OpenCodeServer] #{String.trim(data)}")
    new_buffer = rotate_output_buffer(state.output_buffer <> data)
    {:noreply, %{state | output_buffer: new_buffer}}
  end

  # Handle process exit
  @impl true
  def handle_info({port_ref, {:exit_status, status}}, %{port_ref: port_ref} = state) when is_port(port_ref) do
    Logger.warning("[OpenCodeServer] Process exited with status: #{status}")
    
    new_state = handle_process_exit(state, status)
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  # Handle health check timer
  @impl true
  def handle_info(:health_check, %{running: true} = state) do
    new_state = perform_health_check(state)
    timer = schedule_health_check()
    {:noreply, %{new_state | health_check_timer: timer}}
  end

  @impl true
  def handle_info(:health_check, state) do
    # Not running, don't reschedule
    {:noreply, %{state | health_check_timer: nil}}
  end

  # Handle scheduled restart
  @impl true
  def handle_info({:scheduled_restart, cwd}, state) do
    Logger.info("[OpenCodeServer] Executing scheduled restart")
    
    case check_circuit_breaker(state) do
      {:ok, updated_state} ->
        case do_start_server(cwd, %{updated_state | restart_timer: nil}) do
          {:ok, new_state} ->
            broadcast_status(new_state)
            {:noreply, new_state}
          {:error, _reason, new_state} ->
            {:noreply, new_state}
        end
      
      {:circuit_open, updated_state} ->
        Logger.warning("[OpenCodeServer] Circuit breaker open, not restarting")
        {:noreply, updated_state}
    end
  end

  # Handle session cleanup timer
  @impl true
  def handle_info(:cleanup_stale_sessions, state) do
    new_state = perform_session_cleanup(state)
    timer = schedule_session_cleanup()
    {:noreply, %{new_state | cleanup_timer: timer}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[OpenCodeServer] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("[OpenCodeServer] Terminating, cleaning up...")
    
    # Cancel timers
    if state.health_check_timer, do: Process.cancel_timer(state.health_check_timer)
    if state.restart_timer, do: Process.cancel_timer(state.restart_timer)
    if state.cleanup_timer, do: Process.cancel_timer(state.cleanup_timer)
    
    # Graceful shutdown
    if state.running do
      do_stop_server(state, :terminate)
    end
    
    :ok
  end

  # Private functions

  defp do_start_server(cwd, state) do
    Logger.info("[OpenCodeServer] Starting server on port #{state.port} with cwd: #{cwd}")
    
    args = ["acp", "--port", "#{state.port}", "--hostname", "0.0.0.0", "--cwd", cwd, "--print-logs"]
    
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
      
      # Use readiness probe instead of sleep
      case wait_for_readiness(state.port) do
        :ok ->
          health_timer = schedule_health_check()
          
          new_state = %{state |
            running: true,
            os_pid: os_pid,
            port_ref: port_ref,
            cwd: cwd,
            started_at: DateTime.utc_now(),
            health_status: :healthy,
            last_health_check: DateTime.utc_now(),
            health_check_timer: health_timer,
            consecutive_failures: 0,
            next_restart_delay_ms: @initial_restart_delay_ms
          }
          
          broadcast_status(new_state)
          {:ok, new_state}
          
        {:error, reason} ->
          Logger.error("[OpenCodeServer] Server started but failed readiness check: #{reason}")
          Port.close(port_ref)
          graceful_kill(os_pid)
          
          new_state = record_failure(state)
          {:error, "readiness check failed: #{reason}", new_state}
      end
    rescue
      e ->
        Logger.error("[OpenCodeServer] Failed to start: #{inspect(e)}")
        new_state = record_failure(state)
        {:error, inspect(e), new_state}
    end
  end

  defp do_stop_server(state, reason) do
    Logger.info("[OpenCodeServer] Stopping server (PID: #{state.os_pid}, reason: #{reason})")
    
    # Cancel health check timer
    if state.health_check_timer do
      Process.cancel_timer(state.health_check_timer)
    end
    
    # Close the port
    if state.port_ref && Port.info(state.port_ref) do
      Port.close(state.port_ref)
    end
    
    # Graceful shutdown: SIGTERM first, then SIGKILL
    if state.os_pid do
      graceful_kill(state.os_pid)
    end
    
    %{state |
      running: false,
      os_pid: nil,
      port_ref: nil,
      cwd: nil,
      started_at: nil,
      health_status: :unknown,
      health_check_timer: nil
    }
  end

  defp graceful_kill(os_pid) do
    Logger.debug("[OpenCodeServer] Sending SIGTERM to PID #{os_pid}")
    
    # First try SIGTERM for graceful shutdown
    case CommandRunner.run("kill", ["-15", "#{os_pid}"], timeout: 1_000, stderr_to_stdout: true) do
      {:ok, _} ->
        # Wait for process to exit gracefully
        if wait_for_process_exit(os_pid, @graceful_shutdown_timeout_ms) do
          Logger.debug("[OpenCodeServer] Process #{os_pid} exited gracefully")
        else
          # Force kill if still running
          Logger.warning("[OpenCodeServer] Process #{os_pid} didn't exit gracefully, sending SIGKILL")
          CommandRunner.run("kill", ["-9", "#{os_pid}"], timeout: 1_000, stderr_to_stdout: true)
        end
      
      {:error, _} ->
        # Process might already be dead, try SIGKILL just in case
        CommandRunner.run("kill", ["-9", "#{os_pid}"], timeout: 1_000, stderr_to_stdout: true)
    end
  end

  defp wait_for_process_exit(os_pid, timeout_ms) do
    wait_for_process_exit(os_pid, timeout_ms, 100)
  end

  defp wait_for_process_exit(_os_pid, remaining, _interval) when remaining <= 0, do: false
  defp wait_for_process_exit(os_pid, remaining, interval) do
    case CommandRunner.run("kill", ["-0", "#{os_pid}"], timeout: 500, stderr_to_stdout: true) do
      {:error, _} ->
        # Process doesn't exist (kill -0 failed), it has exited
        true
      {:ok, _} ->
        # Process still exists
        Process.sleep(interval)
        wait_for_process_exit(os_pid, remaining - interval, interval)
    end
  end

  defp wait_for_readiness(port), do: wait_for_readiness(port, @readiness_max_attempts)

  defp wait_for_readiness(_port, 0) do
    {:error, "timeout waiting for server to be ready"}
  end

  defp wait_for_readiness(port, attempts_remaining) do
    case check_server_health(port) do
      :ok ->
        Logger.info("[OpenCodeServer] Server ready after #{@readiness_max_attempts - attempts_remaining + 1} attempts")
        :ok
      
      {:error, _reason} ->
        Process.sleep(@readiness_interval_ms)
        wait_for_readiness(port, attempts_remaining - 1)
    end
  end

  defp check_server_health(port) do
    # Try to connect to the health endpoint
    url = "http://127.0.0.1:#{port}/health"
    
    case http_get(url, @health_check_timeout_ms) do
      {:ok, status} when status in 200..299 ->
        :ok
      
      {:ok, status} ->
        {:error, "unhealthy status: #{status}"}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_get(url, timeout_ms) do
    # Use :httpc for simple HTTP GET (available in OTP)
    # Configure httpc
    :inets.start()
    :ssl.start()
    
    request = {String.to_charlist(url), []}
    http_options = [timeout: timeout_ms, connect_timeout: timeout_ms]
    options = [body_format: :binary]
    
    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_, status_code, _}, _headers, _body}} ->
        {:ok, status_code}
      
      {:error, reason} ->
        {:error, reason}
    end
  catch
    kind, reason ->
      {:error, {kind, reason}}
  end

  defp perform_health_check(state) do
    case check_server_health(state.port) do
      :ok ->
        %{state |
          health_status: :healthy,
          last_health_check: DateTime.utc_now()
        }
      
      {:error, reason} ->
        Logger.warning("[OpenCodeServer] Health check failed: #{inspect(reason)}")
        
        # Mark as unhealthy, but don't immediately restart
        # Let the process exit handler deal with actual crashes
        %{state |
          health_status: :unhealthy,
          last_health_check: DateTime.utc_now()
        }
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval_ms)
  end

  defp handle_process_exit(state, exit_status) do
    # Record this as a failure
    state_with_failure = record_failure(state)
    
    # Clear running state
    cleared_state = %{state_with_failure |
      running: false,
      os_pid: nil,
      port_ref: nil,
      health_status: :unknown
    }
    
    # Cancel health check timer
    final_state =
      if cleared_state.health_check_timer do
        Process.cancel_timer(cleared_state.health_check_timer)
        %{cleared_state | health_check_timer: nil}
      else
        cleared_state
      end
    
    # Schedule restart if auto_restart is enabled and circuit breaker allows
    if final_state.auto_restart && final_state.cwd do
      schedule_restart(final_state, final_state.cwd, exit_status)
    else
      final_state
    end
  end

  defp record_failure(state) do
    now = System.monotonic_time(:millisecond)
    
    # Add current time to restart_times, remove old entries
    cutoff = now - @restart_window_ms
    recent_restarts = Enum.filter(state.restart_times, fn t -> t > cutoff end)
    updated_times = [now | recent_restarts]
    
    %{state |
      restart_count: state.restart_count + 1,
      restart_times: updated_times,
      consecutive_failures: state.consecutive_failures + 1
    }
  end

  defp check_circuit_breaker(state) do
    now = System.monotonic_time(:millisecond)
    
    case state.circuit_state do
      :closed ->
        # Check if we've had too many restarts recently
        cutoff = now - @restart_window_ms
        recent_count = Enum.count(state.restart_times, fn t -> t > cutoff end)
        
        if recent_count >= @max_restarts do
          Logger.error("[OpenCodeServer] Circuit breaker opened: #{recent_count} restarts in #{@restart_window_ms}ms")
          {:circuit_open, %{state | circuit_state: :open, circuit_opened_at: now}}
        else
          {:ok, state}
        end
      
      :open ->
        # Check if cooldown has passed
        if state.circuit_opened_at && now - state.circuit_opened_at > @circuit_breaker_cooldown_ms do
          Logger.info("[OpenCodeServer] Circuit breaker entering half-open state")
          {:ok, %{state | circuit_state: :half_open}}
        else
          {:circuit_open, state}
        end
      
      :half_open ->
        # Allow one attempt
        {:ok, state}
    end
  end

  defp schedule_restart(state, cwd, exit_status) do
    delay = calculate_restart_delay(state)
    
    Logger.info("[OpenCodeServer] Scheduling restart in #{delay}ms (exit status: #{exit_status}, consecutive failures: #{state.consecutive_failures})")
    
    timer = Process.send_after(self(), {:scheduled_restart, cwd}, delay)
    
    # Increase delay for next time (exponential backoff)
    next_delay = min(
      round(delay * @restart_backoff_factor),
      @max_restart_delay_ms
    )
    
    %{state |
      restart_timer: timer,
      next_restart_delay_ms: next_delay
    }
  end

  defp calculate_restart_delay(state) do
    # Use exponential backoff with jitter
    base_delay = state.next_restart_delay_ms
    jitter = :rand.uniform() * 0.25 * base_delay
    round(base_delay + jitter)
  end

  defp rotate_output_buffer(buffer) when byte_size(buffer) > @max_output_buffer_size do
    # Keep only the last portion of the buffer
    Logger.debug("[OpenCodeServer] Rotating output buffer (size: #{byte_size(buffer)})")
    binary_part(buffer, byte_size(buffer) - @output_rotation_size, @output_rotation_size)
  end

  defp rotate_output_buffer(buffer), do: buffer

  defp broadcast_status(state) do
    status = %{
      running: state.running,
      port: state.port,
      cwd: state.cwd,
      pid: state.os_pid,
      started_at: state.started_at,
      health_status: state.health_status,
      restart_count: state.restart_count,
      circuit_state: state.circuit_state
    }
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:opencode_status, status})
  end

  defp schedule_session_cleanup do
    Process.send_after(self(), :cleanup_stale_sessions, @session_cleanup_interval_ms)
  end

  defp perform_session_cleanup(state) do
    # Only cleanup if server is running
    unless state.running do
      Logger.debug("[OpenCodeServer] Skipping session cleanup - server not running")
      state
    else
      case OpenCodeClient.list_sessions() do
        {:ok, sessions} ->
          now_ms = System.system_time(:millisecond)
          stale_sessions = find_stale_sessions(sessions, now_ms)
          deleted_count = delete_stale_sessions(stale_sessions)
          
          if deleted_count > 0 do
            Logger.info("[OpenCodeServer] Cleaned up #{deleted_count} stale session(s)")
            
            ActivityLog.log_event(
              :session_cleanup,
              "Cleaned up #{deleted_count} stale OpenCode session(s)",
              %{count: deleted_count, session_ids: Enum.map(stale_sessions, & &1["id"])}
            )
          else
            Logger.debug("[OpenCodeServer] No stale sessions to cleanup")
          end
          
          state
          
        {:error, reason} ->
          Logger.warning("[OpenCodeServer] Failed to list sessions for cleanup: #{inspect(reason)}")
          state
      end
    end
  end

  defp find_stale_sessions(sessions, now_ms) do
    Enum.filter(sessions, fn session ->
      case get_in(session, ["time", "updated"]) do
        updated_ms when is_integer(updated_ms) ->
          age_ms = now_ms - updated_ms
          age_ms > @session_stale_threshold_ms
          
        _ ->
          # No updated timestamp, consider stale if created long ago
          case get_in(session, ["time", "created"]) do
            created_ms when is_integer(created_ms) ->
              age_ms = now_ms - created_ms
              age_ms > @session_stale_threshold_ms
            _ ->
              false
          end
      end
    end)
  end

  defp delete_stale_sessions(stale_sessions) do
    Enum.reduce(stale_sessions, 0, fn session, count ->
      session_id = session["id"]
      
      case OpenCodeClient.delete_session(session_id) do
        :ok ->
          Logger.debug("[OpenCodeServer] Deleted stale session: #{session_id}")
          count + 1
          
        {:error, reason} ->
          Logger.warning("[OpenCodeServer] Failed to delete session #{session_id}: #{inspect(reason)}")
          count
      end
    end)
  end
end
