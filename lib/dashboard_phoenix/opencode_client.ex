defmodule DashboardPhoenix.OpenCodeClient do
  @moduledoc """
  Client for communicating with the OpenCode ACP server.
  
  The ACP (Agent Client Protocol) uses JSON-RPC for communication.
  This client handles:
  - Initializing a connection
  - Creating sessions
  - Sending prompts/tasks
  - Receiving streaming updates
  
  The OpenCode ACP server exposes a JSON-RPC endpoint over HTTP.
  """
  require Logger

  alias DashboardPhoenix.OpenCodeServer

  @default_timeout 60_000

  @doc """
  Send a task/prompt to the OpenCode ACP server.
  
  This will:
  1. Ensure the server is running
  2. Initialize a connection
  3. Create a new session
  4. Send the prompt
  5. Return the session ID for tracking
  
  Options:
  - :cwd - working directory for the task (default: core-platform)
  - :callback - function to call with streaming updates
  """
  def send_task(prompt, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, "/home/martins/code/core-platform")
    callback = Keyword.get(opts, :callback, &default_callback/1)
    
    # Ensure server is running
    case ensure_server_running(cwd) do
      {:ok, port} ->
        base_url = "http://127.0.0.1:#{port}"
        
        with {:ok, _init_result} <- initialize_connection(base_url),
             {:ok, session_id} <- create_session(base_url),
             {:ok, _} <- send_prompt(base_url, session_id, prompt, callback) do
          {:ok, %{session_id: session_id, port: port}}
        end
        
      {:error, reason} ->
        {:error, "Failed to start OpenCode server: #{inspect(reason)}"}
    end
  end

  @doc """
  Check if the OpenCode server is healthy.
  """
  def health_check do
    case OpenCodeServer.status() do
      %{running: true, port: port} ->
        base_url = "http://127.0.0.1:#{port}"
        # Try a simple request to verify the server is responsive
        case Req.get("#{base_url}/", receive_timeout: 5000) do
          {:ok, %{status: code}} when code in [200, 404] -> :ok
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      _ ->
        {:error, :not_running}
    end
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

  defp initialize_connection(base_url) do
    # ACP Initialize request
    request = %{
      jsonrpc: "2.0",
      id: generate_id(),
      method: "initialize",
      params: %{
        clientInfo: %{
          name: "DashboardPhoenix",
          version: "1.0.0"
        },
        clientCapabilities: %{
          terminal: true,
          "fs.readTextFile": false,
          "fs.writeTextFile": false
        }
      }
    }
    
    send_jsonrpc_request(base_url, request)
  end

  defp create_session(base_url) do
    # ACP session/new request
    request = %{
      jsonrpc: "2.0",
      id: generate_id(),
      method: "session/new",
      params: %{}
    }
    
    case send_jsonrpc_request(base_url, request) do
      {:ok, %{"result" => %{"sessionId" => session_id}}} ->
        {:ok, session_id}
      {:ok, result} ->
        # Try to extract session ID from various response formats
        session_id = get_in(result, ["result", "sessionId"]) || 
                     get_in(result, ["sessionId"]) ||
                     generate_id()
        {:ok, session_id}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_prompt(base_url, session_id, prompt, callback) do
    # ACP prompt request
    request = %{
      jsonrpc: "2.0",
      id: generate_id(),
      method: "prompt",
      params: %{
        sessionId: session_id,
        content: [
          %{type: "text", text: prompt}
        ]
      }
    }
    
    # For streaming, we'll use a simple approach first
    # The full ACP streaming uses SSE or WebSocket
    
    case send_jsonrpc_request(base_url, request) do
      {:ok, result} ->
        # Call callback with the result
        callback.({:result, result})
        {:ok, result}
      {:error, reason} ->
        callback.({:error, reason})
        {:error, reason}
    end
  end

  defp send_jsonrpc_request(base_url, request) do
    url = "#{base_url}/jsonrpc"
    body = Jason.encode!(request)
    
    case Req.post(url, body: body, headers: [{"content-type", "application/json"}], receive_timeout: @default_timeout) do
      {:ok, %{status: 200, body: response_body}} when is_binary(response_body) ->
        case Jason.decode(response_body) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:error, "Invalid JSON response"}
        end
        
      {:ok, %{status: 200, body: response_body}} when is_map(response_body) ->
        # Req might auto-decode JSON
        {:ok, response_body}
        
      {:ok, %{status: code, body: body}} ->
        body_str = if is_binary(body), do: body, else: inspect(body)
        Logger.warning("[OpenCodeClient] Unexpected status #{code}: #{String.slice(body_str, 0, 200)}")
        # The server might be returning HTML for unknown paths
        # Try alternative endpoints
        try_alternative_endpoints(base_url, request)
        
      {:error, %{reason: reason}} ->
        {:error, reason}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_alternative_endpoints(base_url, request) do
    # Try different possible endpoints for the JSON-RPC API
    endpoints = [
      "/api",
      "/rpc",
      "/api/jsonrpc",
      "/"  # Some servers accept POST to root
    ]
    
    body = Jason.encode!(request)
    
    Enum.reduce_while(endpoints, {:error, "No working endpoint found"}, fn endpoint, _acc ->
      url = "#{base_url}#{endpoint}"
      
      case Req.post(url, body: body, headers: [{"content-type", "application/json"}], receive_timeout: @default_timeout) do
        {:ok, %{status: 200, body: response_body}} when is_binary(response_body) ->
          case Jason.decode(response_body) do
            {:ok, %{"result" => _} = result} -> {:halt, {:ok, result}}
            {:ok, %{"error" => _} = result} -> {:halt, {:ok, result}}
            _ -> {:cont, {:error, "Invalid response format"}}
          end
        {:ok, %{status: 200, body: response_body}} when is_map(response_body) ->
          if Map.has_key?(response_body, "result") or Map.has_key?(response_body, "error") do
            {:halt, {:ok, response_body}}
          else
            {:cont, {:error, "Invalid response format"}}
          end
        _ -> 
          {:cont, {:error, "No working endpoint found"}}
      end
    end)
  end

  defp default_callback({:result, result}) do
    Logger.info("[OpenCodeClient] Result: #{inspect(result)}")
  end
  
  defp default_callback({:error, reason}) do
    Logger.error("[OpenCodeClient] Error: #{inspect(reason)}")
  end
  
  defp default_callback({:update, update}) do
    Logger.debug("[OpenCodeClient] Update: #{inspect(update)}")
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
