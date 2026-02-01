defmodule DashboardPhoenix.DeployManager do
  @moduledoc """
  GenServer that manages post-merge deployment pipeline.

  Handles the full deployment cycle:
  1. Debounce rapid deploy requests (10s window)
  2. Restart the systemd service
  3. Wait for service to become active
  4. Health check the application
  5. Log all events to ActivityLog

  ## Usage

      # Trigger a deploy
      DeployManager.trigger_deploy()

      # Check current status
      DeployManager.get_status()

      # Subscribe to deploy events
      DeployManager.subscribe()
  """

  use GenServer
  require Logger

  alias DashboardPhoenix.ActivityLog

  @pubsub_topic "deploy_manager:events"
  @debounce_ms 10_000
  @service_wait_max_ms 30_000
  @service_poll_interval_ms 1_000
  @health_check_retries 3
  @health_check_delay_ms 2_000
  @health_check_url "http://127.0.0.1:4000"
  @repo_path "/home/martins/code/systematic"

  # Behaviour for mocking in tests
  @command_runner Application.compile_env(:dashboard_phoenix, :deploy_command_runner, __MODULE__)
  @http_client Application.compile_env(:dashboard_phoenix, :deploy_http_client, __MODULE__)

  # Status types
  @type status ::
          :idle
          | :pending
          | :restarting
          | :waiting_for_service
          | :health_checking
          | :complete
          | :failed

  @type state :: %{
          status: status(),
          last_deploy: DateTime.t() | nil,
          pending_timer: reference() | nil,
          current_task: Task.t() | nil,
          last_error: String.t() | nil
        }

  # Client API

  @doc "Start the DeployManager GenServer"
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger a deploy.

  Multiple calls within the debounce window (10s) are batched into a single deploy.

  ## Options
  - `:force` - Skip debounce and deploy immediately (default: false)

  ## Returns
  - `{:ok, :triggered}` - Deploy has been triggered
  - `{:ok, :pending}` - Deploy is pending (within debounce window)
  - `{:ok, :already_running}` - Deploy is already in progress
  """
  def trigger_deploy(opts \\ []) do
    GenServer.call(__MODULE__, {:trigger_deploy, opts})
  end

  @doc """
  Get the current deploy status.

  ## Returns
  Map with:
  - `:status` - Current status atom
  - `:last_deploy` - DateTime of last successful deploy
  - `:last_error` - Error message if failed
  """
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc "Subscribe to deploy events via PubSub"
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @pubsub_topic)
  end

  @doc "Unsubscribe from deploy events"
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(DashboardPhoenix.PubSub, @pubsub_topic)
  end

  @doc "Get the PubSub topic"
  def pubsub_topic, do: @pubsub_topic

  @doc "Reset state (for testing)"
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      status: :idle,
      last_deploy: nil,
      pending_timer: nil,
      current_task: nil,
      last_error: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:trigger_deploy, opts}, _from, state) do
    force = Keyword.get(opts, :force, false)

    cond do
      # Already running a deploy
      state.status in [:restarting, :waiting_for_service, :health_checking] ->
        {:reply, {:ok, :already_running}, state}

      # Force deploy - cancel any pending timer and deploy now
      force ->
        state = cancel_pending_timer(state)
        state = start_deploy(state)
        {:reply, {:ok, :triggered}, state}

      # Already have a pending deploy scheduled
      state.status == :pending and state.pending_timer != nil ->
        {:reply, {:ok, :pending}, state}

      # Schedule a debounced deploy
      true ->
        timer = Process.send_after(self(), :execute_pending_deploy, @debounce_ms)

        state = %{state | status: :pending, pending_timer: timer, last_error: nil}
        broadcast_status(state)
        {:reply, {:ok, :pending}, state}
    end
  end

  def handle_call(:get_status, _from, state) do
    status_map = %{
      status: state.status,
      last_deploy: state.last_deploy,
      last_error: state.last_error
    }

    {:reply, status_map, state}
  end

  def handle_call(:reset, _from, state) do
    state = cancel_pending_timer(state)

    if state.current_task do
      Task.shutdown(state.current_task, :brutal_kill)
    end

    new_state = %{
      status: :idle,
      last_deploy: nil,
      pending_timer: nil,
      current_task: nil,
      last_error: nil
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info(:execute_pending_deploy, state) do
    state = %{state | pending_timer: nil}
    state = start_deploy(state)
    {:noreply, state}
  end

  def handle_info({:deploy_result, result}, state) do
    state = handle_deploy_result(result, state)
    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    # Task completed - process result
    Process.demonitor(ref, [:flush])
    state = handle_deploy_result(result, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    # Task crashed
    error = "Deploy task crashed: #{inspect(reason)}"
    Logger.error(error)
    ActivityLog.log_event(:restart_failed, "Deploy crashed", %{error: error})

    state = %{state | status: :failed, current_task: nil, last_error: error}
    broadcast_status(state)
    {:noreply, state}
  end

  # Private Functions

  defp start_deploy(state) do
    # Log that we're starting
    ActivityLog.log_event(:restart_triggered, "Deploy pipeline started")

    # Start async deploy task
    task =
      Task.async(fn ->
        run_deploy_pipeline()
      end)

    state = %{state | status: :restarting, current_task: task, last_error: nil}
    broadcast_status(state)
    state
  end

  defp run_deploy_pipeline do
    with :ok <- restart_service(),
         :ok <- wait_for_service(),
         {:ok, commit} <- get_commit_hash(),
         :ok <- health_check() do
      {:ok, commit}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp restart_service do
    Logger.info("Restarting systematic.service...")

    case @command_runner.run_command("systemctl", ["--user", "restart", "systematic.service"]) do
      {_output, 0} ->
        Logger.info("Service restart command sent")
        :ok

      {output, exit_code} ->
        error = "systemctl restart failed (exit #{exit_code}): #{output}"
        Logger.error(error)
        {:error, error}
    end
  end

  defp wait_for_service do
    Logger.info("Waiting for service to become active...")
    wait_for_service_loop(0)
  end

  defp wait_for_service_loop(elapsed) when elapsed >= @service_wait_max_ms do
    {:error, "Service did not become active within #{@service_wait_max_ms}ms"}
  end

  defp wait_for_service_loop(elapsed) do
    case @command_runner.run_command("systemctl", [
           "--user",
           "is-active",
           "systematic.service"
         ]) do
      {"active\n", 0} ->
        Logger.info("Service is active")
        ActivityLog.log_event(:restart_complete, "Service is active")
        :ok

      _ ->
        Process.sleep(@service_poll_interval_ms)
        wait_for_service_loop(elapsed + @service_poll_interval_ms)
    end
  end

  defp get_commit_hash do
    case @command_runner.run_command("git", ["rev-parse", "--short", "HEAD"], cd: @repo_path) do
      {hash, 0} ->
        {:ok, String.trim(hash)}

      {output, exit_code} ->
        Logger.warning("Could not get commit hash (exit #{exit_code}): #{output}")
        {:ok, "unknown"}
    end
  end

  defp health_check do
    Logger.info("Running health check...")
    health_check_loop(@health_check_retries)
  end

  defp health_check_loop(0) do
    {:error, "Health check failed after #{@health_check_retries} attempts"}
  end

  defp health_check_loop(retries_left) do
    case @http_client.health_check(@health_check_url) do
      {:ok, status} when status in 200..299 ->
        Logger.info("Health check passed (status #{status})")
        :ok

      {:ok, status} ->
        Logger.warning("Health check returned #{status}, retrying...")
        Process.sleep(@health_check_delay_ms)
        health_check_loop(retries_left - 1)

      {:error, reason} ->
        Logger.warning("Health check failed: #{inspect(reason)}, retrying...")
        Process.sleep(@health_check_delay_ms)
        health_check_loop(retries_left - 1)
    end
  end

  defp handle_deploy_result({:ok, commit}, state) do
    ActivityLog.log_event(:deploy_complete, "Deploy successful", %{commit: commit})

    state = %{
      state
      | status: :complete,
        last_deploy: DateTime.utc_now(),
        current_task: nil,
        last_error: nil
    }

    broadcast_status(state)
    state
  end

  defp handle_deploy_result({:error, reason}, state) do
    ActivityLog.log_event(:restart_failed, "Deploy failed", %{error: reason})

    state = %{state | status: :failed, current_task: nil, last_error: reason}
    broadcast_status(state)
    state
  end

  defp cancel_pending_timer(state) do
    if state.pending_timer do
      Process.cancel_timer(state.pending_timer)
    end

    %{state | pending_timer: nil}
  end

  defp broadcast_status(state) do
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @pubsub_topic,
      {:deploy_status, state.status}
    )
  end

  # Default implementations for command runner and HTTP client
  # These are used in production, mocked in tests

  @doc false
  def run_command(cmd, args, opts \\ []) do
    System.cmd(cmd, args, opts)
  end

  @doc false
  def health_check(url) do
    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: status}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end
end
