defmodule DashboardPhoenix.WorkRegistry do
  @moduledoc """
  Central registry for all agent work.

  Tracks every spawned agent (Claude, OpenCode, Gemini) with metadata:
  - agent_type: :claude | :opencode | :gemini
  - session_id: ID from the spawn response
  - ticket_id: optional chainlink/linear ticket
  - source: :chainlink | :linear | :pr_fix | :dashboard | :manual
  - description: human-readable task description
  - model: the model used (opus, sonnet, gemini-2.0-flash, etc.)
  - started_at: when work began
  - status: :running | :completed | :failed

  Persists to JSON for restart survival.
  Provides counts by agent type for round-robin work distribution.
  """

  use GenServer
  require Logger

  @persistence_file "work_registry.json"
  # 1 minute
  @cleanup_interval_ms 60_000
  # Remove inactive agents after 1 hour
  @stale_threshold_hours 1

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc """
  Register new work. Returns {:ok, work_id} or {:error, reason}.

  Required fields:
  - :agent_type - :claude | :opencode | :gemini
  - :description - what the work is about

  Optional fields:
  - :session_id - ID from spawn response (can be added later via update/2)
  - :ticket_id - chainlink or linear ticket ID
  - :source - :chainlink | :linear | :pr_fix | :dashboard | :manual (default: :manual)
  - :model - model name
  - :label - session label
  """
  def register(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:register, attrs})
  end

  @doc "Update a work entry (e.g., add session_id after spawn)"
  def update(work_id, updates) when is_binary(work_id) and is_map(updates) do
    GenServer.call(__MODULE__, {:update, work_id, updates})
  end

  @doc "Mark work as completed"
  def complete(work_id) when is_binary(work_id) do
    GenServer.call(__MODULE__, {:complete, work_id})
  end

  @doc "Mark work as failed"
  def fail(work_id, reason \\ nil) when is_binary(work_id) do
    GenServer.call(__MODULE__, {:fail, work_id, reason})
  end

  @doc "Remove a work entry"
  def remove(work_id) when is_binary(work_id) do
    GenServer.call(__MODULE__, {:remove, work_id})
  end

  @doc "Get all work entries"
  def all do
    GenServer.call(__MODULE__, :all)
  end

  @doc "Get all running work entries"
  def running do
    GenServer.call(__MODULE__, :running)
  end

  @doc "Get all failed work entries (within last 24h)"
  def failed do
    GenServer.call(__MODULE__, :failed)
  end

  @doc "Get recent failures (last N, default 5)"
  def recent_failures(limit \\ 5) do
    GenServer.call(__MODULE__, {:recent_failures, limit})
  end

  @doc "Get work by ID"
  def get(work_id) when is_binary(work_id) do
    GenServer.call(__MODULE__, {:get, work_id})
  end

  @doc "Find work by session_id"
  def find_by_session(session_id) when is_binary(session_id) do
    GenServer.call(__MODULE__, {:find_by_session, session_id})
  end

  @doc "Find work by ticket_id"
  def find_by_ticket(ticket_id) do
    GenServer.call(__MODULE__, {:find_by_ticket, ticket_id})
  end

  @doc "Count running work by agent type"
  def count_by_agent_type do
    GenServer.call(__MODULE__, :count_by_agent_type)
  end

  @doc "Get the agent type with the least running work (for round-robin)"
  def least_busy_agent do
    GenServer.call(__MODULE__, :least_busy_agent)
  end

  @doc "Sync with live session data - marks completed sessions"
  def sync_with_sessions(active_session_ids) when is_list(active_session_ids) do
    GenServer.cast(__MODULE__, {:sync_sessions, active_session_ids})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    work = load_from_file()
    schedule_cleanup()
    {:ok, %{work: work}}
  end

  @impl true
  def handle_call({:register, attrs}, _from, state) do
    work_id = generate_id()

    entry = %{
      id: work_id,
      agent_type: Map.get(attrs, :agent_type) |> normalize_agent_type(),
      session_id: Map.get(attrs, :session_id),
      ticket_id: Map.get(attrs, :ticket_id),
      source: Map.get(attrs, :source, :manual) |> normalize_source(),
      description: Map.get(attrs, :description, "No description"),
      model: Map.get(attrs, :model),
      label: Map.get(attrs, :label),
      status: :running,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    new_work = Map.put(state.work, work_id, entry)
    save_to_file(new_work)

    Logger.info(
      "[WorkRegistry] Registered work #{work_id}: #{entry.agent_type} - #{entry.description}"
    )

    {:reply, {:ok, work_id}, %{state | work: new_work}}
  end

  @impl true
  def handle_call({:update, work_id, updates}, _from, state) do
    case Map.get(state.work, work_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated_entry =
          entry
          |> Map.merge(updates)
          |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

        new_work = Map.put(state.work, work_id, updated_entry)
        save_to_file(new_work)
        {:reply, :ok, %{state | work: new_work}}
    end
  end

  @impl true
  def handle_call({:complete, work_id}, _from, state) do
    case Map.get(state.work, work_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated_entry =
          entry
          |> Map.put(:status, :completed)
          |> Map.put(:completed_at, DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

        new_work = Map.put(state.work, work_id, updated_entry)
        save_to_file(new_work)
        Logger.info("[WorkRegistry] Completed work #{work_id}")
        {:reply, :ok, %{state | work: new_work}}
    end
  end

  @impl true
  def handle_call({:fail, work_id, reason}, _from, state) do
    case Map.get(state.work, work_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      entry ->
        updated_entry =
          entry
          |> Map.put(:status, :failed)
          |> Map.put(:failed_at, DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.put(:failure_reason, reason)
          |> Map.put(:updated_at, DateTime.utc_now() |> DateTime.to_iso8601())

        new_work = Map.put(state.work, work_id, updated_entry)
        save_to_file(new_work)
        Logger.info("[WorkRegistry] Failed work #{work_id}: #{reason}")
        {:reply, :ok, %{state | work: new_work}}
    end
  end

  @impl true
  def handle_call({:remove, work_id}, _from, state) do
    new_work = Map.delete(state.work, work_id)
    save_to_file(new_work)
    {:reply, :ok, %{state | work: new_work}}
  end

  @impl true
  def handle_call(:all, _from, state) do
    {:reply, Map.values(state.work), state}
  end

  @impl true
  def handle_call(:running, _from, state) do
    running =
      state.work
      |> Map.values()
      |> Enum.filter(fn w -> w.status == :running end)

    {:reply, running, state}
  end

  @impl true
  def handle_call(:failed, _from, state) do
    failed =
      state.work
      |> Map.values()
      |> Enum.filter(fn w -> w.status == :failed end)
      |> Enum.sort_by(fn w -> w.failed_at || w.updated_at || "" end, :desc)

    {:reply, failed, state}
  end

  @impl true
  def handle_call({:recent_failures, limit}, _from, state) do
    failures =
      state.work
      |> Map.values()
      |> Enum.filter(fn w -> w.status == :failed end)
      |> Enum.sort_by(fn w -> w.failed_at || w.updated_at || "" end, :desc)
      |> Enum.take(limit)

    {:reply, failures, state}
  end

  @impl true
  def handle_call({:get, work_id}, _from, state) do
    {:reply, Map.get(state.work, work_id), state}
  end

  @impl true
  def handle_call({:find_by_session, session_id}, _from, state) do
    result =
      state.work
      |> Map.values()
      |> Enum.find(fn w -> w.session_id == session_id end)

    {:reply, result, state}
  end

  @impl true
  def handle_call({:find_by_ticket, ticket_id}, _from, state) do
    result =
      state.work
      |> Map.values()
      |> Enum.filter(fn w -> w.ticket_id == ticket_id end)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:count_by_agent_type, _from, state) do
    counts =
      state.work
      |> Map.values()
      |> Enum.filter(fn w -> w.status == :running end)
      |> Enum.group_by(fn w -> w.agent_type end)
      |> Enum.map(fn {type, entries} -> {type, length(entries)} end)
      |> Map.new()

    # Ensure all types are present
    result =
      %{claude: 0, opencode: 0, gemini: 0}
      |> Map.merge(counts)

    {:reply, result, state}
  end

  @impl true
  def handle_call(:least_busy_agent, _from, state) do
    counts =
      state.work
      |> Map.values()
      |> Enum.filter(fn w -> w.status == :running end)
      |> Enum.group_by(fn w -> w.agent_type end)
      |> Enum.map(fn {type, entries} -> {type, length(entries)} end)
      |> Map.new()

    all_counts =
      %{claude: 0, opencode: 0, gemini: 0}
      |> Map.merge(counts)

    {agent_type, _count} = Enum.min_by(all_counts, fn {_type, count} -> count end)
    {:reply, agent_type, state}
  end

  @impl true
  def handle_cast({:sync_sessions, active_session_ids}, state) do
    active_set = MapSet.new(active_session_ids)

    # Mark entries as completed if their session is no longer active
    new_work =
      state.work
      |> Enum.map(fn {id, entry} ->
        cond do
          entry.status != :running ->
            # Already completed/failed, leave as is
            {id, entry}

          is_nil(entry.session_id) ->
            # No session ID yet, leave as running
            {id, entry}

          MapSet.member?(active_set, entry.session_id) ->
            # Session still active
            {id, entry}

          true ->
            # Session no longer active - mark as completed
            {id,
             Map.merge(entry, %{
               status: :completed,
               completed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
               updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
             })}
        end
      end)
      |> Map.new()

    if new_work != state.work do
      save_to_file(new_work)

      completed_count =
        Enum.count(new_work, fn {_id, e} ->
          e.status == :completed and Map.get(state.work[e.id] || %{}, :status) == :running
        end)

      if completed_count > 0 do
        Logger.info("[WorkRegistry] Synced sessions, marked #{completed_count} as completed")
      end
    end

    {:noreply, %{state | work: new_work}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    new_work = cleanup_old_entries(state.work)

    if map_size(new_work) != map_size(state.work) do
      removed = map_size(state.work) - map_size(new_work)
      save_to_file(new_work)
      Logger.info("[WorkRegistry] Cleaned up #{removed} old entries")
    end

    schedule_cleanup()
    {:noreply, %{state | work: new_work}}
  end

  # Private functions

  defp generate_id do
    "work-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp normalize_agent_type(:claude), do: :claude
  defp normalize_agent_type(:opencode), do: :opencode
  defp normalize_agent_type(:gemini), do: :gemini
  defp normalize_agent_type("claude"), do: :claude
  defp normalize_agent_type("opencode"), do: :opencode
  defp normalize_agent_type("gemini"), do: :gemini
  defp normalize_agent_type(_), do: :unknown

  defp normalize_source(:chainlink), do: :chainlink
  defp normalize_source(:linear), do: :linear
  defp normalize_source(:pr_fix), do: :pr_fix
  defp normalize_source(:dashboard), do: :dashboard
  defp normalize_source(:manual), do: :manual
  defp normalize_source("chainlink"), do: :chainlink
  defp normalize_source("linear"), do: :linear
  defp normalize_source("pr_fix"), do: :pr_fix
  defp normalize_source("dashboard"), do: :dashboard
  defp normalize_source(_), do: :manual

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end

  defp cleanup_old_entries(work) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_threshold_hours * 3600, :second)

    work
    |> Enum.filter(fn {_id, entry} ->
      case entry.status do
        # Keep all running
        :running ->
          true

        _ ->
          # Keep completed/failed for 24h
          case DateTime.from_iso8601(entry.updated_at || entry.started_at) do
            {:ok, dt, _} -> DateTime.compare(dt, cutoff) == :gt
            _ -> true
          end
      end
    end)
    |> Map.new()
  end

  defp persistence_path do
    data_dir = Application.get_env(:dashboard_phoenix, :data_dir, "priv/data")
    File.mkdir_p!(data_dir)
    Path.join(data_dir, @persistence_file)
  end

  defp load_from_file do
    path = persistence_path()

    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} ->
            data
            |> Enum.map(fn {id, entry} ->
              # Convert string keys to atoms
              entry =
                for {k, v} <- entry, into: %{} do
                  key = if is_binary(k), do: String.to_atom(k), else: k

                  value =
                    case {key, v} do
                      {:status, s} when is_binary(s) -> String.to_atom(s)
                      {:agent_type, t} when is_binary(t) -> String.to_atom(t)
                      {:source, s} when is_binary(s) -> String.to_atom(s)
                      _ -> v
                    end

                  {key, value}
                end

              {id, entry}
            end)
            |> Map.new()

          _ ->
            %{}
        end

      {:error, :enoent} ->
        %{}

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  defp save_to_file(work) do
    # Get path synchronously (ensures directory exists on first call)
    path = persistence_path()

    # Perform file write asynchronously to avoid blocking the GenServer
    Task.start(fn ->
      try do
        content = Jason.encode!(work, pretty: true)

        # Write to unique temp file first, then rename for atomicity
        # Unique suffix prevents race conditions between concurrent writes
        temp_path = path <> ".tmp.#{:erlang.unique_integer([:positive])}"
        File.write!(temp_path, content)
        File.rename!(temp_path, path)
      rescue
        e ->
          Logger.error("[WorkRegistry] Async save failed: #{inspect(e)}")
      end
    end)

    :ok
  end
end
