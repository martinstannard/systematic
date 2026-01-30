defmodule DashboardPhoenix.SessionBridge do
  @moduledoc """
  Bridges sub-agent progress to the dashboard.
  Tails JSONL progress files written by sub-agents.
  """
  use GenServer
  
  @default_progress_file "/tmp/agent-progress.jsonl"
  @default_sessions_file "/tmp/agent-sessions.json"
  @poll_interval 500  # 500ms for snappy updates

  defp progress_file do
    Application.get_env(:dashboard_phoenix, :progress_file, @default_progress_file)
  end

  defp sessions_file do
    Application.get_env(:dashboard_phoenix, :sessions_file, @default_sessions_file)
  end

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_sessions do
    GenServer.call(__MODULE__, :get_sessions)
  end

  def get_progress do
    GenServer.call(__MODULE__, :get_progress)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, "agent_updates")
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    # Ensure files exist
    File.write(progress_file(), "", [:append])
    File.write(sessions_file(), ~s({"sessions":[]}))
    
    schedule_poll()
    {:ok, %{
      sessions: [],
      progress: [],
      progress_offset: 0,
      last_session_mtime: nil
    }}
  end

  @impl true
  def handle_call(:get_sessions, _from, state) do
    {:reply, state.sessions, state}
  end

  @impl true
  def handle_call(:get_progress, _from, state) do
    {:reply, state.progress, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = state
    |> poll_progress()
    |> poll_sessions()
    
    schedule_poll()
    {:noreply, new_state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  # Tail the JSONL progress file for new lines
  defp poll_progress(state) do
    case File.stat(progress_file()) do
      {:ok, %{size: size}} when size > state.progress_offset ->
        case File.open(progress_file(), [:read]) do
          {:ok, file} ->
            :file.position(file, state.progress_offset)
            new_lines = IO.read(file, :eof)
            File.close(file)
            
            new_events = parse_progress_lines(new_lines)
            
            if new_events != [] do
              # Keep last 100 events
              updated_progress = (state.progress ++ new_events) |> Enum.take(-100)
              broadcast_progress(new_events)
              %{state | progress: updated_progress, progress_offset: size}
            else
              %{state | progress_offset: size}
            end
          {:error, _} ->
            state
        end
      _ ->
        state
    end
  end

  defp parse_progress_lines(data) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_progress_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_progress_line(line) do
    case Jason.decode(line) do
      {:ok, event} -> normalize_event(event)
      {:error, _} -> nil
    end
  end

  defp normalize_event(e) do
    %{
      ts: e["ts"] || System.system_time(:millisecond),
      agent: e["agent"] || "unknown",
      action: e["action"] || "unknown",
      target: e["target"] || "",
      status: e["status"] || "running",
      output: e["output"] || "",
      details: e["details"] || ""
    }
  end

  # Poll the sessions JSON file
  defp poll_sessions(state) do
    case File.stat(sessions_file()) do
      {:ok, %{mtime: mtime}} when mtime != state.last_session_mtime ->
        case File.read(sessions_file()) do
          {:ok, content} ->
            case Jason.decode(content) do
              {:ok, %{"sessions" => sessions}} ->
                normalized = Enum.map(sessions, &normalize_session/1)
                broadcast_sessions(normalized)
                %{state | sessions: normalized, last_session_mtime: mtime}
              _ ->
                state
            end
          {:error, _} ->
            state
        end
      _ ->
        state
    end
  end

  defp normalize_session(s) do
    %{
      id: s["id"] || s["label"] || "unknown",
      label: s["label"] || s["id"],
      status: s["status"] || "running",
      task: s["task"] || "",
      started_at: s["started_at"],
      agent_type: s["agent_type"] || "subagent",
      model: s["model"] || "sonnet",
      current_action: s["current_action"],
      last_output: s["last_output"],
      # Stats
      tokens_in: s["tokens_in"] || 0,
      tokens_out: s["tokens_out"] || 0,
      total_tokens: s["total_tokens"] || 0,
      cost: s["cost"] || 0.0,
      runtime: s["runtime"] || "0s",
      session_key: s["session_key"]
    }
  end

  defp broadcast_progress(events) do
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "agent_updates", {:progress, events})
  end

  defp broadcast_sessions(sessions) do
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "agent_updates", {:sessions, sessions})
  end
end
