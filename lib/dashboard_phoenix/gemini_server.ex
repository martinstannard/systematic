defmodule DashboardPhoenix.GeminiServer do
  @moduledoc """
  GenServer that manages Gemini CLI one-shot commands.
  
  The Gemini CLI doesn't support interactive mode via Elixir Port (no TTY),
  so this server runs one-shot commands: `gemini "prompt" --cwd <cwd>`
  
  This GenServer:
  - Verifies the Gemini CLI is available
  - Runs prompts as one-shot commands
  - Captures and broadcasts output via PubSub
  - Tracks whether the server is "enabled" (ready to accept prompts)
  """
  use GenServer
  require Logger

  alias DashboardPhoenix.Paths
  alias DashboardPhoenix.CommandRunner

  @pubsub DashboardPhoenix.PubSub
  @topic "gemini_server"

  defp gemini_bin, do: Paths.gemini_bin()
  defp default_cwd, do: Paths.default_work_dir()

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enable the Gemini server (verify binary exists, set running: true).
  """
  def start_server(cwd \\ nil) do
    GenServer.call(__MODULE__, {:start_server, cwd || default_cwd()}, 10_000)
  end

  @doc """
  Disable the Gemini server (set running: false).
  """
  def stop_server do
    GenServer.call(__MODULE__, :stop_server)
  end

  @doc """
  Get current server status.
  Returns a map with :running, :cwd, :started_at, :busy
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Check if the server is enabled and ready for prompts.
  """
  def running? do
    status().running
  end

  @doc """
  Send a prompt to Gemini CLI as a one-shot command.
  Returns :ok immediately; output is broadcast via PubSub.
  """
  def send_prompt(prompt) when is_binary(prompt) do
    GenServer.call(__MODULE__, {:send_prompt, prompt}, 5_000)
  end

  @doc """
  Subscribe to server status changes and output.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    cwd = Keyword.get(opts, :cwd) || default_cwd()
    
    state = %{
      running: false,
      cwd: cwd,
      started_at: nil,
      busy: false,
      gemini_path: nil
    }
    
    {:ok, state}
  end

  @impl true
  def handle_call({:start_server, _cwd}, _from, %{running: true} = state) do
    Logger.info("[GeminiServer] Already enabled")
    {:reply, {:ok, :already_running}, state}
  end

  @impl true
  def handle_call({:start_server, cwd}, _from, state) do
    Logger.info("[GeminiServer] Enabling Gemini CLI with cwd: #{cwd}")
    
    # Check if gemini binary exists
    gemini_path = find_gemini_binary()
    
    if gemini_path do
      # Verify it runs (quick version check)
      case CommandRunner.run(gemini_path, ["--version"], timeout: 10_000, stderr_to_stdout: true) do
        {:ok, output} ->
          Logger.info("[GeminiServer] Gemini CLI available: #{String.trim(output)}")
          
          new_state = %{state |
            running: true,
            cwd: cwd,
            started_at: DateTime.utc_now(),
            gemini_path: gemini_path
          }
          
          broadcast_status(new_state)
          {:reply, {:ok, :started}, new_state}
        
        {:error, :timeout} ->
          Logger.error("[GeminiServer] Gemini CLI version check timed out")
          {:reply, {:error, "Gemini CLI version check timed out"}, state}
        
        {:error, {:exit, code, error}} ->
          Logger.error("[GeminiServer] Gemini CLI check failed (exit #{code}): #{error}")
          {:reply, {:error, "Gemini CLI check failed: #{error}"}, state}
        
        {:error, reason} ->
          Logger.error("[GeminiServer] Gemini CLI check error: #{inspect(reason)}")
          {:reply, {:error, "Gemini CLI check failed: #{inspect(reason)}"}, state}
      end
    else
      Logger.error("[GeminiServer] Gemini CLI not found")
      {:reply, {:error, "Gemini CLI not found at #{gemini_bin()}"}, state}
    end
  end

  @impl true
  def handle_call(:stop_server, _from, state) do
    Logger.info("[GeminiServer] Disabling server")
    
    new_state = %{state |
      running: false,
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
      started_at: state.started_at,
      busy: state.busy
    }
    {:reply, status, state}
  end

  @impl true
  def handle_call({:send_prompt, _prompt}, _from, %{running: false} = state) do
    {:reply, {:error, :not_running}, state}
  end

  @impl true
  def handle_call({:send_prompt, _prompt}, _from, %{busy: true} = state) do
    {:reply, {:error, :busy}, state}
  end

  @impl true
  def handle_call({:send_prompt, prompt}, _from, state) do
    # Mark as busy and run async
    new_state = %{state | busy: true}
    broadcast_status(new_state)
    
    # Spawn a task to run the command and send output back
    parent = self()
    Task.start(fn ->
      result = run_gemini_prompt(state.gemini_path, prompt, state.cwd)
      send(parent, {:prompt_complete, result})
    end)
    
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:prompt_complete, {:ok, output}}, state) do
    Logger.info("[GeminiServer] Prompt completed successfully")
    
    # Broadcast the output
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_output, output})
    
    new_state = %{state | busy: false}
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:prompt_complete, {:error, error}}, state) do
    Logger.error("[GeminiServer] Prompt failed: #{error}")
    
    # Broadcast the error as output
    error_msg = "\n[ERROR] #{error}\n"
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_output, error_msg})
    
    new_state = %{state | busy: false}
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("[GeminiServer] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp find_gemini_binary do
    path = gemini_bin()
    cond do
      File.exists?(path) -> path
      File.exists?("/usr/local/bin/gemini") -> "/usr/local/bin/gemini"
      true ->
        # Try to find it in PATH with timeout
        case CommandRunner.run("which", ["gemini"], timeout: 5_000, stderr_to_stdout: true) do
          {:ok, output} -> String.trim(output)
          _ -> nil
        end
    end
  end

  defp run_gemini_prompt(gemini_path, prompt, cwd) do
    Logger.info("[GeminiServer] Running gemini in #{cwd}: #{String.slice(prompt, 0, 50)}...")
    
    # Broadcast that we're starting
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_output, "\n> #{prompt}\n\n"})
    
    # Run the gemini command with the prompt
    # The gemini CLI accepts the prompt as a positional argument
    # Use longer timeout for AI processing, but not infinite
    case CommandRunner.run(gemini_path, [prompt],
           timeout: 120_000,  # 2 minutes for AI processing
           cd: cwd,
           stderr_to_stdout: true,
           env: [{"NO_COLOR", "1"}, {"TERM", "dumb"}]) do
      {:ok, output} ->
        {:ok, output}
      
      {:error, :timeout} ->
        {:error, "Gemini command timed out after 2 minutes"}
      
      {:error, {:exit, exit_code, output}} ->
        # Still return output even on non-zero exit (might be useful info)
        Logger.warning("[GeminiServer] Command exited with code #{exit_code}")
        {:ok, output <> "\n[Exit code: #{exit_code}]"}
      
      {:error, reason} ->
        {:error, "Gemini command failed: #{inspect(reason)}"}
    end
  end

  defp broadcast_status(state) do
    status = %{
      running: state.running,
      cwd: state.cwd,
      started_at: state.started_at,
      busy: state.busy
    }
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_status, status})
  end
end
