defmodule DashboardPhoenix.ChainlinkWorkTracker do
  @moduledoc """
  Persists Chainlink work-in-progress status to survive server restarts.

  Stores active work sessions in a JSON file, tracking:
  - Which tickets are being worked on
  - Agent/session information
  - When work started

  Work is automatically cleaned up when:
  - Explicitly marked complete via `complete_work/1`
  - Session is no longer running (detected during sync)
  - Entry is older than 24 hours (stale cleanup)
  """

  use GenServer
  require Logger

  @persistence_file "chainlink_work_progress.json"
  @stale_threshold_hours 24
  # 5 minutes
  @cleanup_interval_ms 300_000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc "Record that work has started on an issue"
  def start_work(issue_id, work_info) when is_integer(issue_id) do
    GenServer.call(__MODULE__, {:start_work, issue_id, work_info})
  end

  @doc "Mark work as complete on an issue"
  def complete_work(issue_id) when is_integer(issue_id) do
    GenServer.call(__MODULE__, {:complete_work, issue_id})
  end

  @doc "Get all persisted work in progress"
  def get_all_work do
    GenServer.call(__MODULE__, :get_all_work)
  end

  @doc "Sync with live session data - removes entries for sessions no longer running"
  def sync_with_sessions(active_session_ids) when is_list(active_session_ids) do
    GenServer.cast(__MODULE__, {:sync_sessions, active_session_ids})
  end

  @doc "Check if an issue has persisted work (even if session not detected)"
  def has_work?(issue_id) when is_integer(issue_id) do
    GenServer.call(__MODULE__, {:has_work, issue_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    work = load_from_file()
    schedule_cleanup()
    {:ok, %{work: work}}
  end

  @impl true
  def handle_call({:start_work, issue_id, work_info}, _from, state) do
    entry =
      Map.merge(work_info, %{
        started_at: DateTime.utc_now() |> DateTime.to_iso8601()
      })

    new_work = Map.put(state.work, issue_id, entry)
    save_to_file(new_work)
    {:reply, :ok, %{state | work: new_work}}
  end

  @impl true
  def handle_call({:complete_work, issue_id}, _from, state) do
    new_work = Map.delete(state.work, issue_id)
    save_to_file(new_work)
    {:reply, :ok, %{state | work: new_work}}
  end

  @impl true
  def handle_call(:get_all_work, _from, state) do
    {:reply, state.work, state}
  end

  @impl true
  def handle_call({:has_work, issue_id}, _from, state) do
    {:reply, Map.has_key?(state.work, issue_id), state}
  end

  @impl true
  def handle_cast({:sync_sessions, active_session_ids}, state) do
    # Remove entries where session is no longer running
    active_set = MapSet.new(active_session_ids)

    new_work =
      state.work
      |> Enum.filter(fn {_issue_id, info} ->
        session_id = Map.get(info, :session_id) || Map.get(info, "session_id")
        # Keep if no session_id (manual work) or session is still active
        is_nil(session_id) or MapSet.member?(active_set, session_id)
      end)
      |> Map.new()

    if map_size(new_work) != map_size(state.work) do
      save_to_file(new_work)

      Logger.info(
        "ChainlinkWorkTracker: cleaned up #{map_size(state.work) - map_size(new_work)} stale entries"
      )
    end

    {:noreply, %{state | work: new_work}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    new_work = cleanup_stale_entries(state.work)

    if map_size(new_work) != map_size(state.work) do
      save_to_file(new_work)

      Logger.info(
        "ChainlinkWorkTracker: cleaned up #{map_size(state.work) - map_size(new_work)} stale entries"
      )
    end

    schedule_cleanup()
    {:noreply, %{state | work: new_work}}
  end

  # Private functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_stale_entries(work) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_threshold_hours * 3600, :second)

    work
    |> Enum.filter(fn {_issue_id, info} ->
      case Map.get(info, :started_at) || Map.get(info, "started_at") do
        # Keep entries without timestamp
        nil ->
          true

        timestamp_str ->
          case DateTime.from_iso8601(timestamp_str) do
            {:ok, timestamp, _} -> DateTime.compare(timestamp, cutoff) == :gt
            # Keep if can't parse
            _ -> true
          end
      end
    end)
    |> Map.new()
  end

  defp persistence_path do
    # Store in the app's priv directory or a data directory
    data_dir = Application.get_env(:dashboard_phoenix, :data_dir, "priv/data")

    case File.mkdir_p(data_dir) do
      :ok ->
        Path.join(data_dir, @persistence_file)

      {:error, reason} ->
        Logger.error(
          "ChainlinkWorkTracker: Failed to create data directory #{data_dir}: #{inspect(reason)}"
        )

        # Fallback to tmp directory
        tmp_path = Path.join(System.tmp_dir!(), @persistence_file)
        Logger.warning("ChainlinkWorkTracker: Using fallback path #{tmp_path}")
        tmp_path
    end
  end

  defp load_from_file do
    path = persistence_path()

    try do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} ->
              # Convert string keys to integer issue IDs
              data
              |> Enum.map(fn {k, v} ->
                issue_id = if is_binary(k), do: String.to_integer(k), else: k
                # Convert string keys in value to atoms for consistency
                info =
                  for {key, val} <- v, into: %{} do
                    atom_key = if is_binary(key), do: String.to_atom(key), else: key
                    {atom_key, val}
                  end

                {issue_id, info}
              end)
              |> Map.new()

            {:error, %Jason.DecodeError{} = e} ->
              Logger.warning(
                "ChainlinkWorkTracker: Failed to parse JSON from #{path}: #{Exception.message(e)}"
              )

              %{}

            {:error, reason} ->
              Logger.warning(
                "ChainlinkWorkTracker: JSON decode error from #{path}: #{inspect(reason)}"
              )

              %{}
          end

        {:error, :enoent} ->
          Logger.debug("ChainlinkWorkTracker: Persistence file #{path} does not exist")
          %{}

        {:error, :eacces} ->
          Logger.warning("ChainlinkWorkTracker: Permission denied reading #{path}")
          %{}

        {:error, reason} ->
          Logger.warning("ChainlinkWorkTracker: Failed to read #{path}: #{inspect(reason)}")
          %{}
      end
    rescue
      e ->
        Logger.error("ChainlinkWorkTracker: Exception loading from file: #{inspect(e)}")
        %{}
    end
  end

  defp save_to_file(work) do
    path = persistence_path()

    try do
      case Jason.encode(work, pretty: true) do
        {:ok, content} ->
          case File.write(path, content) do
            :ok ->
              Logger.debug("ChainlinkWorkTracker: Successfully saved work tracker data")
              :ok

            {:error, reason} ->
              Logger.error("ChainlinkWorkTracker: Failed to write to #{path}: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, %Jason.EncodeError{} = e} ->
          Logger.error(
            "ChainlinkWorkTracker: Failed to encode work data as JSON: #{Exception.message(e)}"
          )

          {:error, {:json_encode, e}}

        {:error, reason} ->
          Logger.error("ChainlinkWorkTracker: JSON encode error: #{inspect(reason)}")
          {:error, {:json_encode, reason}}
      end
    rescue
      e ->
        Logger.error("ChainlinkWorkTracker: Exception saving work tracker data: #{inspect(e)}")
        {:error, {:exception, e}}
    end
  end
end
