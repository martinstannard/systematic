defmodule DashboardPhoenix.OpenCodeActivityMonitor do
  @moduledoc """
  Monitors OpenCode tool calls and broadcasts them to the Live Feed.
  
  OpenCode stores its data in ~/.local/share/opencode/storage/:
  - session/<project-hash>/<session-id>.json - Session metadata
  - part/<message-id>/<part-id>.json - Tool calls and responses
  - message/<session-id>/ - Message directories
  
  This GenServer polls the part/ directory for recent tool calls and broadcasts
  them as progress events to the "agent_updates" PubSub topic, making them appear
  in the Live Feed alongside OpenClaw sub-agent activity.
  """
  use GenServer

  require Logger

  @poll_interval 3_000  # Poll every 3 seconds
  @lookback_seconds 300  # Look at parts from last 5 minutes
  @max_events 50  # Keep last 50 events to avoid memory bloat

  # OpenCode storage location
  defp storage_dir do
    Path.join([System.user_home!(), ".local", "share", "opencode", "storage"])
  end

  defp parts_dir, do: Path.join(storage_dir(), "part")
  defp sessions_dir, do: Path.join(storage_dir(), "session")

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def get_progress do
    GenServer.call(__MODULE__, :get_progress)
  end

  @impl true
  def init(_) do
    schedule_poll()
    {:ok, %{
      progress: [],
      seen_part_ids: MapSet.new(),
      session_titles: %{}  # Cache session titles: %{session_id => title}
    }}
  end

  @impl true
  def handle_call(:get_progress, _from, state) do
    {:reply, state.progress, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = poll_opencode_parts(state)
    schedule_poll()
    {:noreply, new_state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  # Main polling function - finds recent tool call parts
  defp poll_opencode_parts(state) do
    case File.ls(parts_dir()) do
      {:ok, message_dirs} ->
        cutoff = System.system_time(:second) - @lookback_seconds
        
        # Find recent part files across all message directories
        {new_events, seen_ids} = message_dirs
        |> Enum.flat_map(fn msg_dir ->
          msg_path = Path.join(parts_dir(), msg_dir)
          case File.ls(msg_path) do
            {:ok, part_files} ->
              part_files
              |> Enum.filter(&String.ends_with?(&1, ".json"))
              |> Enum.map(fn file -> Path.join(msg_path, file) end)
            {:error, _} -> []
          end
        end)
        |> Enum.filter(fn path ->
          case File.stat(path) do
            {:ok, %{mtime: mtime}} ->
              # Safely convert mtime with error handling
              try do
                epoch = mtime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()
                epoch > cutoff
              rescue
                _ -> false
              end
            {:error, _} -> false
          end
        end)
        |> Enum.reduce({[], state.seen_part_ids}, fn path, {events_acc, seen_acc} ->
          case parse_part_file(path, seen_acc, state.session_titles) do
            {:ok, event, part_id} ->
              {[event | events_acc], MapSet.put(seen_acc, part_id)}
            :skip ->
              {events_acc, seen_acc}
          end
        end)
        
        if new_events != [] do
          # Sort by timestamp, newest last
          sorted_events = Enum.sort_by(new_events, & &1.ts)
          
          # Merge with existing progress, keep last N events
          updated_progress = (state.progress ++ sorted_events)
          |> Enum.uniq_by(& &1.ts)
          |> Enum.sort_by(& &1.ts)
          |> Enum.take(-@max_events)
          
          # Broadcast to PubSub
          broadcast_progress(sorted_events)
          
          %{state | progress: updated_progress, seen_part_ids: seen_ids}
        else
          %{state | seen_part_ids: seen_ids}
        end
        
      {:error, :enoent} ->
        # OpenCode storage doesn't exist yet, that's fine
        state

      {:error, reason} ->
        Logger.debug("[OpenCodeActivityMonitor] Failed to list parts dir: #{inspect(reason)}")
        state
    end
  end

  # Parse a part JSON file and convert to progress event format
  defp parse_part_file(path, seen_ids, session_titles) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- Jason.decode(content) do
      part_id = data["id"]
      
      # Skip if already seen or not a tool call
      cond do
        MapSet.member?(seen_ids, part_id) ->
          :skip
        data["type"] != "tool" ->
          :skip
        true ->
          event = build_progress_event(data, session_titles)
          {:ok, event, part_id}
      end
    else
      _ -> :skip
    end
  end

  # Convert OpenCode part data to progress event format matching SessionBridge
  defp build_progress_event(data, session_titles) do
    state = data["state"] || %{}
    input = state["input"] || %{}
    time = state["time"] || %{}
    
    # Get timestamp - prefer start time, fallback to current time
    ts = time["start"] || System.system_time(:millisecond)
    
    # Map OpenCode tool names to display names
    tool_name = data["tool"] || "unknown"
    action = normalize_tool_name(tool_name)
    
    # Extract target based on tool type
    target = extract_target(tool_name, input)
    
    # Determine status
    status = case state["status"] do
      "completed" -> "done"
      "running" -> "running"
      "error" -> "error"
      _ -> "running"
    end
    
    # Get session title for agent label
    session_id = data["sessionID"]
    agent_label = Map.get(session_titles, session_id) || get_session_title(session_id) || "OpenCode"
    
    # Build output summary
    output_summary = build_output_summary(tool_name, state)
    
    %{
      ts: ts,
      agent: agent_label,
      agent_type: "OpenCode",
      action: action,
      target: truncate_target(target),
      status: status,
      output: truncate_output(state["output"] || ""),
      output_summary: output_summary,
      details: ""
    }
  end

  # Normalize OpenCode tool names to match SessionBridge conventions
  defp normalize_tool_name("read"), do: "Read"
  defp normalize_tool_name("write"), do: "Write"
  defp normalize_tool_name("edit"), do: "Edit"
  defp normalize_tool_name("bash"), do: "Bash"
  defp normalize_tool_name("glob"), do: "Glob"
  defp normalize_tool_name("grep"), do: "Grep"
  defp normalize_tool_name("find"), do: "Find"
  defp normalize_tool_name("patch"), do: "Edit"
  defp normalize_tool_name("webFetch"), do: "WebFetch"
  defp normalize_tool_name("todoRead"), do: "TodoRead"
  defp normalize_tool_name("todoWrite"), do: "TodoWrite"
  defp normalize_tool_name(name), do: String.capitalize(name)

  # Extract the most relevant target from tool input
  defp extract_target("read", %{"filePath" => path}), do: path
  defp extract_target("write", %{"filePath" => path}), do: path
  defp extract_target("edit", %{"filePath" => path}), do: path
  defp extract_target("patch", %{"filePath" => path}), do: path
  defp extract_target("bash", %{"command" => cmd}), do: cmd
  defp extract_target("glob", %{"pattern" => pattern}), do: pattern
  defp extract_target("grep", %{"pattern" => pattern}), do: pattern
  defp extract_target("find", %{"pattern" => pattern}), do: pattern
  defp extract_target("webFetch", %{"url" => url}), do: url
  defp extract_target(_, input) do
    # Try common field names
    input["path"] || input["file"] || input["command"] || input["query"] || input["pattern"] || ""
  end

  # Build a short output summary for the UI
  defp build_output_summary(tool_name, state) do
    output = state["output"] || ""
    metadata = state["metadata"] || %{}
    is_error = state["status"] == "error"
    
    cond do
      is_error -> "❌ Error"
      tool_name == "bash" ->
        lines = output |> String.split("\n") |> length()
        "✓ #{lines} lines"
      tool_name == "read" ->
        if metadata["truncated"], do: "📄 truncated", else: "📄 read"
      tool_name == "write" -> "✓ written"
      tool_name == "edit" -> "✓ edited"
      tool_name == "patch" -> "✓ patched"
      tool_name == "glob" ->
        count = metadata["count"] || (output |> String.split("\n", trim: true) |> length())
        "#{count} files"
      tool_name == "grep" ->
        lines = output |> String.split("\n", trim: true) |> length()
        "#{lines} matches"
      String.length(output) > 0 ->
        "✓ #{String.length(output)} chars"
      true ->
        "✓ done"
    end
  end

  # Get session title from session file (with caching potential)
  defp get_session_title(nil), do: nil
  defp get_session_title(session_id) do
    # Find session file - it's stored under project dirs
    case File.ls(sessions_dir()) do
      {:ok, project_dirs} ->
        project_dirs
        |> Enum.find_value(fn project_dir ->
          session_path = Path.join([sessions_dir(), project_dir, "#{session_id}.json"])
          case File.read(session_path) do
            {:ok, content} ->
              case Jason.decode(content) do
                {:ok, %{"title" => title}} when title != "" and not is_nil(title) ->
                  # Return truncated title or slug
                  truncate_title(title)
                {:ok, %{"slug" => slug}} ->
                  slug
                _ -> nil
              end
            _ -> nil
          end
        end)
      _ -> nil
    end
  end

  defp truncate_title(title) when byte_size(title) > 30 do
    String.slice(title, 0, 27) <> "..."
  end
  defp truncate_title(title), do: title

  defp truncate_target(target) when is_binary(target) do
    if String.length(target) > 80 do
      String.slice(target, 0, 77) <> "..."
    else
      target
    end
  end
  defp truncate_target(_), do: ""

  defp truncate_output(output) when is_binary(output) do
    if String.length(output) > 500 do
      String.slice(output, 0, 500) <> "..."
    else
      output
    end
  end
  defp truncate_output(_), do: ""

  defp broadcast_progress(events) do
    Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, "agent_updates", {:progress, events})
  end
end
