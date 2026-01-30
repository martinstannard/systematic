defmodule DashboardPhoenix.SessionUpdater do
  @moduledoc """
  Periodically runs the session update script to keep the JSON file fresh.
  """
  use GenServer
  
  @update_interval 1_000  # 1 second
  @script_path Path.expand("../../scripts/update_sessions.sh", __DIR__)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
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
    System.cmd("bash", [@script_path], stderr_to_stdout: true)
  end
end
