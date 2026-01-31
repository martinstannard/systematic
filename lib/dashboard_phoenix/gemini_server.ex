defmodule DashboardPhoenix.GeminiServer do
  @moduledoc """
  GenServer that manages a Gemini CLI interactive process.
  
  The Gemini CLI is Google's AI coding assistant that runs in interactive mode.
  
  This GenServer:
  - Starts the Gemini CLI in interactive mode
  - Monitors the process health
  - Provides status information
  - Handles cleanup on shutdown
  - Allows sending prompts to the running session
  """
  use GenServer
  require Logger

  @gemini_bin "/usr/bin/gemini"
  @default_cwd "/home/martins/work/core-platform"
  
  @pubsub DashboardPhoenix.PubSub
  @topic "gemini_server"

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start the Gemini CLI if not already running.
  """
  def start_server(cwd \\ @default_cwd) do
    GenServer.call(__MODULE__, {:start_server, cwd}, 30_000)
  end

  @doc """
  Stop the Gemini CLI.
  """
  def stop_server do
    GenServer.call(__MODULE__, :stop_server)
  end

  @doc """
  Get current server status.
  Returns a map with :running, :cwd, :pid, :started_at
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Check if the server is running.
  """
  def running? do
    status().running
  end

  @doc """
  Send a prompt to the running Gemini session.
  """
  def send_prompt(prompt) when is_binary(prompt) do
    GenServer.call(__MODULE__, {:send_prompt, prompt}, 60_000)
  end

  @doc """
  Get recent output from the Gemini session.
  """
  def get_output(lines \\ 100) do
    GenServer.call(__MODULE__, {:get_output, lines})
  end

  @doc """
  List sessions (Gemini stores session history).
  """
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions, 10_000)
  end

  @doc """
  Subscribe to server status changes.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd, @default_cwd)
    
    state = %{
      running: false,
      os_pid: nil,
      port_ref: nil,
      cwd: cwd,
      started_at: nil,
      output_buffer: "",
      output_lines: []
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call({:start_server, _cwd}, _from, %{running: true} = state) do
    Logger.info("[GeminiServer] Server already running")
    {:reply, {:ok, :already_running}, state}
  end

  @impl true
  def handle_call({:start_server, cwd}, _from, state) do
    Logger.info("[GeminiServer] Starting Gemini CLI with cwd: #{cwd}")
    
    # Check if gemini binary exists
    gemini_path = find_gemini_binary()
    
    if gemini_path do
      # Start Gemini in interactive mode with sandbox disabled for full functionality
      # Using --yolo for auto-approval in controlled dashboard environment
      args = ["--sandbox", "false"]
      
      port_opts = [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        {:args, args},
        {:cd, cwd},
        {:env, [
          {~c"TERM", ~c"dumb"},
          {~c"NO_COLOR", ~c"1"}
        ]}
      ]
      
      try do
        port_ref = Port.open({:spawn_executable, gemini_path}, port_opts)
        {:os_pid, os_pid} = Port.info(port_ref, :os_pid)
        
        Logger.info("[GeminiServer] Started with OS PID: #{os_pid}")
        
        new_state = %{state |
          running: true,
          os_pid: os_pid,
          port_ref: port_ref,
          cwd: cwd,
          started_at: DateTime.utc_now(),
          output_buffer: "",
          output_lines: []
        }
        
        broadcast_status(new_state)
        {:reply, {:ok, os_pid}, new_state}
      rescue
        e ->
          Logger.error("[GeminiServer] Failed to start: #{inspect(e)}")
          {:reply, {:error, inspect(e)}, state}
      end
    else
      Logger.error("[GeminiServer] Gemini CLI not found")
      {:reply, {:error, "Gemini CLI not found. Install with: npm install -g @anthropic-ai/claude-code"}, state}
    end
  end

  @impl true
  def handle_call(:stop_server, _from, %{running: false} = state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:stop_server, _from, state) do
    Logger.info("[GeminiServer] Stopping server (PID: #{state.os_pid})")
    
    if state.port_ref do
      # Send quit command first
      try do
        Port.command(state.port_ref, "/quit\n")
        Process.sleep(500)
      catch
        _, _ -> :ok
      end
      
      # Then close the port
      try do
        Port.close(state.port_ref)
      catch
        _, _ -> :ok
      end
    end
    
    # Also kill the OS process to be sure
    if state.os_pid do
      System.cmd("kill", ["-9", "#{state.os_pid}"], stderr_to_stdout: true)
    end
    
    new_state = %{state |
      running: false,
      os_pid: nil,
      port_ref: nil,
      started_at: nil
    }
    
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      running: state.running,
      cwd: state.cwd,
      pid: state.os_pid,
      started_at: state.started_at,
      output_lines: length(state.output_lines)
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call({:send_prompt, prompt}, _from, %{running: false} = state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:send_prompt, prompt}, _from, state) do
    try do
      # Send the prompt followed by newline
      Port.command(state.port_ref, prompt <> "\n")
      {:reply, :ok, state}
    catch
      kind, reason ->
        Logger.error("[GeminiServer] Failed to send prompt: #{inspect({kind, reason})}")
        {:reply, {:error, {kind, reason}}, state}
    end
  end

  @impl true
  def handle_call({:get_output, lines}, _from, state) do
    output = state.output_lines
    |> Enum.take(-lines)
    |> Enum.join("\n")
    {:reply, output, state}
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    # Run gemini --list-sessions to get available sessions
    case System.cmd("gemini", ["--list-sessions"], stderr_to_stdout: true, cd: state.cwd) do
      {output, 0} ->
        sessions = parse_session_list(output)
        {:reply, {:ok, sessions}, state}
      {error, _} ->
        {:reply, {:error, error}, state}
    end
  catch
    _, reason ->
      {:reply, {:error, reason}, state}
  end

  # Handle port messages (stdout/stderr from the process)
  @impl true
  def handle_info({port_ref, {:data, data}}, %{port_ref: port_ref} = state) when is_port(port_ref) do
    # Log output from the Gemini process
    lines = String.split(data, "\n", trim: false)
    new_lines = state.output_lines ++ lines
    # Keep only last 1000 lines to avoid memory issues
    new_lines = Enum.take(new_lines, -1000)
    
    Logger.debug("[GeminiServer] #{String.trim(data)}")
    
    # Broadcast output update
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_output, data})
    
    {:noreply, %{state | output_buffer: state.output_buffer <> data, output_lines: new_lines}}
  end

  # Handle process exit
  @impl true
  def handle_info({port_ref, {:exit_status, status}}, %{port_ref: port_ref} = state) when is_port(port_ref) do
    Logger.warning("[GeminiServer] Process exited with status: #{status}")
    
    new_state = %{state |
      running: false,
      os_pid: nil,
      port_ref: nil
    }
    
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[GeminiServer] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port_ref: port_ref, os_pid: os_pid}) do
    Logger.info("[GeminiServer] Terminating, cleaning up...")
    
    if port_ref && Port.info(port_ref) do
      try do
        Port.close(port_ref)
      catch
        _, _ -> :ok
      end
    end
    
    if os_pid do
      System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
    end
    
    :ok
  end

  # Private functions

  defp find_gemini_binary do
    cond do
      File.exists?(@gemini_bin) -> @gemini_bin
      File.exists?("/usr/local/bin/gemini") -> "/usr/local/bin/gemini"
      true ->
        # Try to find it in PATH
        case System.cmd("which", ["gemini"], stderr_to_stdout: true) do
          {path, 0} -> String.trim(path)
          _ -> nil
        end
    end
  end

  defp broadcast_status(state) do
    status = %{
      running: state.running,
      cwd: state.cwd,
      pid: state.os_pid,
      started_at: state.started_at
    }
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_status, status})
  end

  defp parse_session_list(output) do
    # Parse the output of gemini --list-sessions
    # Format is typically: "1. Session title (date)"
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.match?(&1, ~r/^\d+\./))
    |> Enum.map(fn line ->
      # Extract session number and title
      case Regex.run(~r/^(\d+)\.\s+(.+)$/, line) do
        [_, num, title] -> %{index: String.to_integer(num), title: String.trim(title)}
        _ -> nil
      end
    end)
    |> Enum.filter(& &1)
  end
end
