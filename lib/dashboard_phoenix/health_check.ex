defmodule DashboardPhoenix.HealthCheck do
  @moduledoc """
  Periodic health check that pings the dashboard endpoint.
  
  Broadcasts health status updates via PubSub for UI components to display.
  """
  use GenServer
  require Logger

  alias DashboardPhoenix.PubSub.Topics

  @check_interval :timer.seconds(30)
  @health_url "http://127.0.0.1:4000/"
  @timeout 5_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc "Subscribe to health check updates"
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, Topics.health_check())
  end

  @doc "Get current health status"
  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  @doc "Trigger an immediate health check"
  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    state = %{
      status: :unknown,
      last_check: nil,
      last_error: nil
    }
    
    # Schedule first check after a short delay
    Process.send_after(self(), :check, 1_000)
    
    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    new_state = perform_check(state)
    broadcast(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = perform_check(state)
    broadcast(new_state)
    
    # Schedule next check
    Process.send_after(self(), :check, @check_interval)
    
    {:noreply, new_state}
  end

  # Private Functions

  defp perform_check(state) do
    now = DateTime.utc_now()
    
    case do_health_check() do
      :ok ->
        %{state | status: :healthy, last_check: now, last_error: nil}
      
      {:error, reason} ->
        Logger.warning("Health check failed: #{inspect(reason)}")
        %{state | status: :unhealthy, last_check: now, last_error: reason}
    end
  end

  defp do_health_check do
    case :httpc.request(:get, {@health_url |> String.to_charlist(), []}, 
           [{:timeout, @timeout}, {:connect_timeout, @timeout}], []) do
      {:ok, {{_, status_code, _}, _headers, _body}} when status_code in 200..299 ->
        :ok
      
      {:ok, {{_, status_code, reason}, _headers, _body}} ->
        {:error, "HTTP #{status_code}: #{reason}"}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      Topics.health_check(),
      {:health_update, state}
    )
  end
end
