defmodule DashboardPhoenix.OpenCodeClient do
  @moduledoc """
  Client for communicating with the OpenCode ACP server.
  
  The ACP server exposes a REST API:
  - GET /session - list sessions
  - POST /session - create a new session
  - POST /session/{id}/message - send a message to a session
  
  Messages use the format: {"parts": [{"type": "text", "text": "..."}]}
  """
  require Logger

  @behaviour DashboardPhoenix.Behaviours.OpenCodeClientBehaviour

  alias DashboardPhoenix.OpenCodeServer
  alias DashboardPhoenix.Paths

  @default_timeout 120_000

  @doc """
  Send a task/prompt to the OpenCode ACP server.
  
  This will:
  1. Ensure the server is running
  2. Create a new session
  3. Send the prompt
  4. Return immediately (task runs async in OpenCode)
  
  Options:
  - :cwd - working directory for the task (default: core-platform)
  - :model - model to request from OpenCode (currently not used, OpenCode uses its own model config)
  - :timeout - request timeout in ms
  """
  def send_task(prompt, opts \\ []) do
    cwd = Keyword.get(opts, :cwd) || Paths.default_work_dir()
    model = Keyword.get(opts, :model, nil)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    
    Logger.info("[OpenCodeClient] Sending task with model: #{model || "default"}")
    
    # Ensure server is running
    case ensure_server_running(cwd) do
      {:ok, port} ->
        base_url = "http://127.0.0.1:#{port}"
        
        # Note: OpenCode model selection is not currently supported via API
        # The model parameter is accepted for interface consistency but not used
        with {:ok, session} <- create_session(base_url, timeout),
             {:ok, _} <- send_message(base_url, session["id"], prompt, timeout) do
          {:ok, %{session_id: session["id"], slug: session["slug"], port: port}}
        end
        
      {:error, reason} ->
        {:error, "Failed to start OpenCode server: #{format_error(reason)}"}
    end
  end

  @doc """
  Check if the OpenCode server is healthy.
  """
  def health_check do
    case OpenCodeServer.status() do
      %{running: true, port: port} ->
        base_url = "http://127.0.0.1:#{port}"
        case Req.get("#{base_url}/session", receive_timeout: 5000) do
          {:ok, %{status: 200}} -> :ok
          {:ok, %{status: code}} -> {:error, "HTTP #{code}: unexpected status"}
          {:error, %{reason: reason}} -> {:error, "Connection failed: #{reason}"}
          {:error, reason} -> {:error, "Connection failed: #{format_error(reason)}"}
        end
      _ ->
        {:error, :not_running}
    end
  end

  @doc """
  List all sessions from the OpenCode server.
  """
  def list_sessions do
    case OpenCodeServer.status() do
      %{running: true, port: port} ->
        base_url = "http://127.0.0.1:#{port}"
        case Req.get("#{base_url}/session", receive_timeout: 5000) do
          {:ok, %{status: 200, body: body}} when is_list(body) -> 
            {:ok, body}
          {:ok, %{status: 200, body: body}} when is_binary(body) -> 
            case Jason.decode(body) do
              {:ok, data} -> {:ok, data}
              {:error, _} -> {:error, "Invalid JSON response from server"}
            end
          {:ok, %{status: code}} ->
            {:error, "HTTP #{code}: failed to list sessions"}
          {:error, reason} -> 
            {:error, "Connection failed: #{format_error(reason)}"}
        end
      _ ->
        {:error, :not_running}
    end
  end

  @doc """
  List sessions formatted for dashboard display.
  Returns a list of maps with: id, slug, title, status, created_at, file_changes
  """
  def list_sessions_formatted do
    case list_sessions() do
      {:ok, sessions} when is_list(sessions) ->
        formatted = sessions
        |> Enum.map(&format_session/1)
        |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
        {:ok, formatted}
      
      {:error, :not_running} ->
        {:error, :not_running}
      
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Send a message to an existing session.
  
  This is fire-and-forget - the task runs async in OpenCode.
  Returns {:ok, :sent} immediately or {:error, reason}.
  """
  def send_message(session_id, prompt) do
    case OpenCodeServer.status() do
      %{running: true, port: port} ->
        base_url = "http://127.0.0.1:#{port}"
        send_message_to_session(base_url, session_id, prompt)
      _ ->
        {:error, :not_running}
    end
  end

  @doc """
  Delete/close a session by ID.
  """
  def delete_session(session_id) do
    case OpenCodeServer.status() do
      %{running: true, port: port} ->
        base_url = "http://127.0.0.1:#{port}"
        case Req.delete("#{base_url}/session/#{session_id}", receive_timeout: 5000) do
          {:ok, %{status: code}} when code in [200, 204] -> :ok
          {:ok, %{status: 404}} -> {:error, "Session not found"}
          {:ok, %{status: code}} -> {:error, "HTTP #{code}: failed to delete session"}
          {:error, reason} -> {:error, "Connection failed: #{format_error(reason)}"}
        end
      _ ->
        {:error, "Server not running"}
    end
  end

  defp format_session(session) do
    time = session["time"] || %{}
    summary = session["summary"] || %{}
    
    created_at = case time["created"] do
      ts when is_integer(ts) -> DateTime.from_unix!(ts, :millisecond)
      _ -> nil
    end
    
    updated_at = case time["updated"] do
      ts when is_integer(ts) -> DateTime.from_unix!(ts, :millisecond)
      _ -> nil
    end
    
    # Determine status based on activity
    status = cond do
      session["parentID"] -> "subagent"
      updated_at && DateTime.diff(DateTime.utc_now(), updated_at, :second) < 60 -> "active"
      true -> "idle"
    end
    
    %{
      id: session["id"],
      slug: session["slug"],
      title: session["title"] || session["slug"],
      status: status,
      directory: session["directory"],
      created_at: created_at,
      updated_at: updated_at,
      file_changes: %{
        additions: summary["additions"] || 0,
        deletions: summary["deletions"] || 0,
        files: summary["files"] || 0
      },
      parent_id: session["parentID"]
    }
  end

  # Private functions

  defp ensure_server_running(cwd) do
    case OpenCodeServer.status() do
      %{running: true, port: port} ->
        {:ok, port}
      _ ->
        OpenCodeServer.start_server(cwd)
    end
  end

  defp create_session(base_url, timeout) do
    Logger.info("[OpenCodeClient] Creating new session...")
    
    case Req.post("#{base_url}/session", 
      json: %{},
      receive_timeout: timeout
    ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        Logger.info("[OpenCodeClient] Created session: #{body["id"]} (#{body["slug"]})")
        {:ok, body}
        
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, session} -> {:ok, session}
          {:error, _} -> {:error, "Invalid JSON response"}
        end
        
      {:ok, %{status: code, body: body}} ->
        Logger.error("[OpenCodeClient] Failed to create session: #{code} - #{inspect(body)}")
        {:error, "Failed to create session: #{code}"}
        
      {:error, reason} ->
        Logger.error("[OpenCodeClient] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp send_message(base_url, session_id, prompt, _timeout) do
    Logger.info("[OpenCodeClient] Sending message to session #{session_id}...")
    
    # OpenCode expects messages in parts format
    payload = %{
      parts: [
        %{type: "text", text: prompt}
      ]
    }
    
    # Fire and forget - spawn a task to send the message
    # We return immediately since OpenCode will take minutes to complete
    url = "#{base_url}/session/#{session_id}/message"
    
    # Use supervised task to prevent silent crashes and enable resource control
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        case Req.post(url, json: payload, receive_timeout: 600_000) do
          {:ok, %{status: code}} when code in [200, 201, 202] ->
            Logger.info("[OpenCodeClient] OpenCode task completed successfully")
          {:ok, %{status: code, body: body}} ->
            Logger.warning("[OpenCodeClient] OpenCode returned #{code}: #{inspect(body)}")
          {:error, reason} ->
            Logger.warning("[OpenCodeClient] OpenCode request ended: #{inspect(reason)}")
        end
      rescue
        e ->
          Logger.error("[OpenCodeClient] Task crashed in send_message: #{Exception.message(e)}")
          Logger.error("[OpenCodeClient] Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}")
      end
    end)
    
    # Return immediately - task is running in background
    Logger.info("[OpenCodeClient] Message dispatched to OpenCode (running in background)")
    {:ok, :sent}
  end

  # Send message to an existing session (public API version)
  defp send_message_to_session(base_url, session_id, prompt) do
    Logger.info("[OpenCodeClient] Sending message to existing session #{session_id}...")
    
    payload = %{
      parts: [
        %{type: "text", text: prompt}
      ]
    }
    
    url = "#{base_url}/session/#{session_id}/message"
    
    # Fire and forget - use supervised task to prevent silent crashes
    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      try do
        case Req.post(url, json: payload, receive_timeout: 600_000) do
          {:ok, %{status: code}} when code in [200, 201, 202] ->
            Logger.info("[OpenCodeClient] Message sent successfully to session #{session_id}")
          {:ok, %{status: code, body: body}} ->
            Logger.warning("[OpenCodeClient] OpenCode returned #{code}: #{inspect(body)}")
          {:error, reason} ->
            Logger.warning("[OpenCodeClient] OpenCode request failed: #{format_error(reason)}")
        end
      rescue
        e ->
          Logger.error("[OpenCodeClient] Task crashed in send_message_to_session: #{Exception.message(e)}")
          Logger.error("[OpenCodeClient] Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}")
      end
    end)
    
    {:ok, :sent}
  end

  # Format error reasons into human-readable strings
  defp format_error(%{reason: reason}) when is_atom(reason), do: to_string(reason)
  defp format_error(%{original: original}) when is_atom(original), do: to_string(original)
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
