defmodule DashboardPhoenix.SessionUpdater do
  @moduledoc """
  Periodically runs the session update script to keep the JSON file fresh.
  """
  use GenServer
  
  alias DashboardPhoenix.{CommandRunner, Paths}
  require Logger
  
  @update_interval 1_000  # 1 second

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__, hibernate_after: 15_000)
  end

  @impl true
  def init(_) do
    schedule_update()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:update, state) do
    run_update()
    schedule_update()
    {:noreply, state}
  end

  defp schedule_update do
    Process.send_after(self(), :update, @update_interval)
  end

  defp run_update do
    script_path = Paths.session_update_script()
    # Short timeout for the update script since it runs every second
    case CommandRunner.run("bash", [script_path], timeout: 5_000, stderr_to_stdout: true) do
      {:ok, _output} -> :ok
      {:error, :timeout} -> 
        Logger.warning("[SessionUpdater] Update script timed out after 5s")
      {:error, reason} -> 
        Logger.warning("[SessionUpdater] Update script failed: #{inspect(reason)}")
    end
  end
end
