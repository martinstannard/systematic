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
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
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
  Returns a map with :running, :cwd, :started_at, :busy, :sessions
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
  List available Gemini sessions for the current project.
  """
  def list_sessions do
    GenServer.call(__MODULE__, :list_sessions, 10_000)
  end

  @doc """
  Refresh the session list from Gemini CLI.
  """
  def refresh_sessions do
    GenServer.cast(__MODULE__, :refresh_sessions)
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
    auto_start = Keyword.get(opts, :auto_start, true)

    state = %{
      running: false,
      cwd: cwd,
      started_at: nil,
      busy: false,
      gemini_path: nil,
      auto_start: auto_start,
      sessions: []
    }

    if auto_start do
      send(self(), :auto_start)
    end

    {:ok, state}
  end

  # All handle_call clauses grouped together

  @impl true
  def handle_call({:start_server, _cwd}, _from, %{running: true} = state) do
    Logger.info("[GeminiServer] Already enabled")
    {:reply, {:ok, :already_running}, state}
  end

  def handle_call({:start_server, cwd}, _from, state) do
    Logger.info("[GeminiServer] Enabling Gemini CLI with cwd: #{cwd}")

    gemini_path = find_gemini_binary()

    if gemini_path do
      case CommandRunner.run(gemini_path, ["--version"], timeout: 10_000, stderr_to_stdout: true) do
        {:ok, output} ->
          Logger.info("[GeminiServer] Gemini CLI available: #{String.trim(output)}")

          new_state = %{
            state
            | running: true,
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

          {:reply, {:error, "Gemini CLI check failed (exit #{code}): #{String.trim(error)}"},
           state}

        {:error, reason} ->
          Logger.error("[GeminiServer] Gemini CLI check error: #{inspect(reason)}")
          {:reply, {:error, "Gemini CLI check failed: #{format_error(reason)}"}, state}
      end
    else
      Logger.error("[GeminiServer] Gemini CLI not found")
      {:reply, {:error, "Gemini CLI not found at #{gemini_bin()}"}, state}
    end
  end

  def handle_call(:stop_server, _from, state) do
    Logger.info("[GeminiServer] Disabling server")

    new_state = %{state | running: false, started_at: nil}
    broadcast_status(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call(:status, _from, state) do
    status = %{
      running: state.running,
      cwd: state.cwd,
      started_at: state.started_at,
      busy: state.busy,
      sessions: Map.get(state, :sessions, [])
    }

    {:reply, status, state}
  end

  def handle_call(:list_sessions, _from, state) do
    {:reply, {:ok, Map.get(state, :sessions, [])}, state}
  end

  def handle_call({:send_prompt, _prompt}, _from, %{running: false} = state) do
    {:reply, {:error, :not_running}, state}
  end

  def handle_call({:send_prompt, _prompt}, _from, %{busy: true} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_prompt, prompt}, _from, state) do
    new_state = %{state | busy: true}
    broadcast_status(new_state)

    parent = self()

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      result = run_gemini_prompt(state.gemini_path, prompt, state.cwd)
      send(parent, {:prompt_complete, result})
    end)

    {:reply, :ok, new_state}
  end

  # All handle_cast clauses grouped together

  @impl true
  def handle_cast(:refresh_sessions, state) do
    if state.running and state.gemini_path do
      case CommandRunner.run(state.gemini_path, ["--list-sessions"],
             timeout: 10_000,
             cd: state.cwd,
             stderr_to_stdout: true
           ) do
        {:ok, output} ->
          sessions = parse_session_list(output)
          new_state = %{state | sessions: sessions}
          broadcast_status(new_state)
          {:noreply, new_state}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # All handle_info clauses grouped together

  @impl true
  def handle_info(:auto_start, state) do
    Logger.info("[GeminiServer] Auto-starting on boot...")

    gemini_path = find_gemini_binary()

    if gemini_path do
      case CommandRunner.run(gemini_path, ["--version"], timeout: 10_000, stderr_to_stdout: true) do
        {:ok, output} ->
          Logger.info("[GeminiServer] Auto-start successful: #{String.trim(output)}")

          new_state = %{
            state
            | running: true,
              cwd: state.cwd,
              started_at: DateTime.utc_now(),
              gemini_path: gemini_path
          }

          broadcast_status(new_state)
          send(self(), :refresh_sessions)
          {:noreply, new_state}

        {:error, reason} ->
          Logger.warning(
            "[GeminiServer] Auto-start failed: #{inspect(reason)}, will retry on demand"
          )

          {:noreply, state}
      end
    else
      Logger.warning("[GeminiServer] Gemini CLI not found, will retry on demand")
      {:noreply, state}
    end
  end

  def handle_info(:refresh_sessions, state) do
    if state.running and state.gemini_path do
      case CommandRunner.run(state.gemini_path, ["--list-sessions"],
             timeout: 10_000,
             cd: state.cwd,
             stderr_to_stdout: true
           ) do
        {:ok, output} ->
          sessions = parse_session_list(output)
          {:noreply, %{state | sessions: sessions}}

        _ ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:prompt_complete, {:ok, output}}, state) do
    Logger.info("[GeminiServer] Prompt completed successfully")

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_output, output})

    new_state = %{state | busy: false}
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  def handle_info({:prompt_complete, {:error, :timeout}}, state) do
    Logger.error("[GeminiServer] Prompt timed out")

    error_msg = "\n[ERROR] Command timed out after 10 minutes\n"
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_output, error_msg})

    new_state = %{state | busy: false}
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  def handle_info({:prompt_complete, {:error, error}}, state) do
    Logger.error("[GeminiServer] Prompt failed: #{error}")

    error_msg = "\n[ERROR] #{error}\n"
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_output, error_msg})

    new_state = %{state | busy: false}
    broadcast_status(new_state)
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.debug("[GeminiServer] Unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private functions

  defp find_gemini_binary do
    path = gemini_bin()

    cond do
      File.exists?(path) ->
        path

      File.exists?("/usr/local/bin/gemini") ->
        "/usr/local/bin/gemini"

      true ->
        case CommandRunner.run("which", ["gemini"], timeout: 5_000, stderr_to_stdout: true) do
          {:ok, output} -> String.trim(output)
          _ -> nil
        end
    end
  end

  defp run_gemini_prompt(gemini_path, prompt, cwd) do
    Logger.info("[GeminiServer] Running gemini in #{cwd}: #{String.slice(prompt, 0, 50)}...")

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_output, "\n> #{prompt}\n\n"})

    case CommandRunner.run(gemini_path, [prompt],
           # 10 minutes for coding work
           timeout: 600_000,
           cd: cwd,
           stderr_to_stdout: true,
           env: [{"NO_COLOR", "1"}, {"TERM", "dumb"}]
         ) do
      {:ok, output} ->
        {:ok, output}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, {:exit, exit_code, output}} ->
        Logger.warning("[GeminiServer] Command exited with code #{exit_code}")
        {:ok, output <> "\n[Exit code: #{exit_code}]"}

      {:error, reason} ->
        {:error, "Gemini command failed: #{format_error(reason)}"}
    end
  end

  defp broadcast_status(state) do
    status = %{
      running: state.running,
      cwd: state.cwd,
      started_at: state.started_at,
      busy: state.busy,
      sessions: Map.get(state, :sessions, [])
    }

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:gemini_status, status})
  end

  defp parse_session_list(output) when is_binary(output) do
    output
    |> String.split("\n")
    |> Enum.filter(fn line -> Regex.match?(~r/^\d+\.\s+/, line) end)
    |> Enum.map(fn line ->
      case Regex.run(~r/^(\d+)\.\s+(.+?)(?:\s+\((.+)\))?$/, line) do
        [_, index, name, time] ->
          %{index: String.to_integer(index), name: String.trim(name), time: time}

        [_, index, name] ->
          %{index: String.to_integer(index), name: String.trim(name), time: nil}

        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_session_list(_), do: []

  defp format_error(%{reason: reason}) when is_atom(reason), do: to_string(reason)
  defp format_error(%{original: original}) when is_atom(original), do: to_string(original)
  defp format_error(reason) when is_atom(reason), do: to_string(reason)
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
