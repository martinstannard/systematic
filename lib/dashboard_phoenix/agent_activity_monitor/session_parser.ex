defmodule DashboardPhoenix.AgentActivityMonitor.SessionParser do
  @moduledoc """
  Parses OpenClaw/Claude session JSONL files to extract agent activity.
  
  This module is stateless and can be used independently of the AgentActivityMonitor
  GenServer for testing or batch processing.
  
  ## Session File Format
  
  OpenClaw sessions are stored as JSONL files with events like:
  - `{"type": "session", "id": "...", "cwd": "..."}`
  - `{"type": "model_change", "modelId": "claude-opus"}`
  - `{"type": "message", "message": {"role": "assistant", "content": [...]}}`
  
  Tool calls are embedded in message content as:
  - `{"type": "toolCall", "name": "Read", "arguments": {"path": "..."}}`
  """

  require Logger

  @type action :: %{
          action: String.t(),
          target: String.t() | nil,
          timestamp: DateTime.t() | nil
        }

  @type agent_activity :: %{
          id: String.t(),
          session_id: String.t(),
          type: :openclaw | :claude_code | :opencode | :codex | :unknown,
          model: String.t(),
          cwd: String.t() | nil,
          status: String.t(),
          last_action: action() | nil,
          recent_actions: list(action()),
          files_worked: list(String.t()),
          last_activity: DateTime.t(),
          tool_call_count: non_neg_integer()
        }

  @max_recent_actions 10

  @doc """
  Parses a session file and returns agent activity.
  
  ## Options
  - `:max_actions` - Maximum recent actions to keep (default: 10)
  """
  @spec parse_file(String.t(), keyword()) :: {:ok, agent_activity()} | {:error, term()}
  def parse_file(path, opts \\ []) do
    max_actions = Keyword.get(opts, :max_actions, @max_recent_actions)
    
    case File.read(path) do
      {:ok, content} ->
        filename = Path.basename(path)
        activity = parse_content(content, filename, max_actions: max_actions)
        {:ok, activity}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Parses session content (JSONL string) and returns agent activity.
  
  This is the core parsing function - useful for testing or when content
  is already in memory.
  """
  @spec parse_content(String.t(), String.t(), keyword()) :: agent_activity()
  def parse_content(content, filename, opts \\ []) do
    max_actions = Keyword.get(opts, :max_actions, @max_recent_actions)
    
    lines = String.split(content, "\n", trim: true)
    events = lines
    |> Enum.map(&parse_jsonl_line/1)
    |> Enum.reject(&is_nil/1)
    
    extract_agent_activity(events, filename, max_actions)
  end

  @doc """
  Parses a single JSONL line into a map.
  Returns nil on parse failure.
  """
  @spec parse_jsonl_line(String.t()) :: map() | nil
  def parse_jsonl_line(line) do
    case Jason.decode(line) do
      {:ok, data} -> data
      {:error, %Jason.DecodeError{} = e} ->
        Logger.debug("SessionParser: Failed to decode JSON line: #{Exception.message(e)}")
        nil
      {:error, reason} ->
        Logger.debug("SessionParser: JSON decode error: #{inspect(reason)}")
        nil
    end
  rescue
    e ->
      Logger.debug("SessionParser: Exception decoding JSON line: #{inspect(e)}")
      nil
  end

  @doc """
  Extracts agent activity from a list of parsed events.
  """
  @spec extract_agent_activity(list(map()), String.t(), pos_integer()) :: agent_activity()
  def extract_agent_activity(events, filename, max_actions \\ @max_recent_actions) do
    # Find session info
    session_event = Enum.find(events, & &1["type"] == "session")
    session_id = if session_event, do: session_event["id"], else: String.replace(filename, ".jsonl", "")
    cwd = if session_event, do: session_event["cwd"], else: nil
    
    # Find model info
    model_event = Enum.find(events, & &1["type"] == "model_change")
    model = if model_event, do: model_event["modelId"], else: "unknown"
    
    # Extract recent tool calls
    tool_calls = extract_tool_calls(events, max_actions)
    
    # Get last action
    last_action = List.last(tool_calls)
    
    # Extract files being worked on from tool calls
    files_worked = tool_calls
    |> Enum.flat_map(&extract_files_from_tool_call/1)
    |> Enum.uniq()
    |> Enum.take(-10)
    
    # Determine status
    last_message = events
    |> Enum.filter(& &1["type"] == "message")
    |> List.last()
    
    status = determine_status(last_message, tool_calls)
    
    # Get the last activity timestamp
    last_activity = cond do
      last_action && last_action.timestamp ->
        last_action.timestamp
      last_message && last_message["timestamp"] ->
        parse_timestamp(last_message["timestamp"])
      true ->
        DateTime.utc_now()
    end
    
    %{
      id: "openclaw-#{session_id}",
      session_id: session_id,
      type: :openclaw,
      model: model,
      cwd: cwd,
      status: status,
      last_action: format_action(last_action),
      recent_actions: Enum.map(tool_calls, &format_action/1),
      files_worked: files_worked,
      last_activity: last_activity,
      tool_call_count: length(tool_calls)
    }
  end

  @doc """
  Extracts tool calls from events.
  """
  @spec extract_tool_calls(list(map()), pos_integer()) :: list(map())
  def extract_tool_calls(events, max_actions \\ @max_recent_actions) do
    events
    |> Enum.filter(fn e -> 
      e["type"] == "message" and 
      e["message"]["role"] == "assistant" and
      is_list(e["message"]["content"])
    end)
    |> Enum.flat_map(fn e ->
      e["message"]["content"]
      |> Enum.filter(& is_map(&1) and &1["type"] == "toolCall")
      |> Enum.map(fn tc ->
        %{
          name: tc["name"],
          arguments: tc["arguments"],
          timestamp: parse_timestamp(e["timestamp"])
        }
      end)
    end)
    |> Enum.take(-max_actions)
  end

  @doc """
  Extracts file paths from a tool call.
  """
  @spec extract_files_from_tool_call(map()) :: list(String.t())
  def extract_files_from_tool_call(%{name: name, arguments: args}) when is_map(args) do
    cond do
      name in ["Read", "read"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["Write", "write"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["Edit", "edit"] -> [args["path"] || args["file_path"]] |> Enum.reject(&is_nil/1)
      name in ["exec", "Bash"] -> extract_files_from_command(args["command"] || "")
      true -> []
    end
  end
  def extract_files_from_tool_call(_), do: []

  @doc """
  Extracts file paths from a shell command.
  """
  @spec extract_files_from_command(term()) :: list(String.t())
  def extract_files_from_command(command) when is_binary(command) do
    Regex.scan(~r{(?:^|\s)([~/.][\w./\-]+\.\w+)}, command)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.take(5)
  end
  def extract_files_from_command(_), do: []

  @doc """
  Determines the agent status from the last message and tool calls.
  """
  @spec determine_status(map() | nil, list(map())) :: String.t()
  def determine_status(last_message, tool_calls) do
    cond do
      is_nil(last_message) -> "idle"
      last_message["message"]["role"] == "assistant" and 
        has_pending_tool_calls?(last_message) -> "executing"
      last_message["message"]["role"] == "toolResult" -> "thinking"
      last_message["message"]["role"] == "user" -> "processing"
      length(tool_calls) == 0 -> "idle"
      true -> "active"
    end
  end

  @doc """
  Checks if a message has pending tool calls.
  """
  @spec has_pending_tool_calls?(map()) :: boolean()
  def has_pending_tool_calls?(message) do
    content = message["message"]["content"] || []
    Enum.any?(content, & is_map(&1) and &1["type"] == "toolCall")
  end

  @doc """
  Formats a tool call into an action map.
  """
  @spec format_action(map() | nil) :: action() | nil
  def format_action(nil), do: nil
  def format_action(%{name: name, arguments: args, timestamp: ts}) do
    target = cond do
      is_map(args) and args["path"] -> truncate(args["path"], 50)
      is_map(args) and args["file_path"] -> truncate(args["file_path"], 50)
      is_map(args) and args["command"] -> truncate(args["command"], 50)
      true -> nil
    end
    
    %{
      action: name,
      target: target,
      timestamp: parse_timestamp(ts)
    }
  end

  @doc """
  Parses an ISO8601 or Unix timestamp into DateTime.
  """
  @spec parse_timestamp(term()) :: DateTime.t()
  def parse_timestamp(nil), do: DateTime.utc_now()
  def parse_timestamp(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
  def parse_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts, :millisecond)
  end
  def parse_timestamp(%DateTime{} = dt), do: dt
  def parse_timestamp(_), do: DateTime.utc_now()

  @doc """
  Truncates a string to max length with ellipsis.
  """
  @spec truncate(term(), pos_integer()) :: String.t()
  def truncate(str, max) when is_binary(str) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end
  def truncate(_, _), do: ""
end
