defmodule DashboardPhoenix.GitMonitor do
  @moduledoc """
  Monitors git repository for commit and merge events.

  Detects:
  - New commits on the main branch (and optionally other tracked branches)
  - Merge commits (commits with multiple parents)

  Logs events to ActivityLog with commit hash, message summary, and author.
  """

  use GenServer
  require Logger

  alias DashboardPhoenix.{ActivityLog, CommandRunner, Paths}

  # 60 seconds
  @poll_interval_ms 60_000
  @cli_timeout_ms 30_000
  @topic "git_monitor"

  defp repo_path, do: Paths.systematic_repo()

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__, hibernate_after: 15_000)
  end

  @doc "Get current monitor state"
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc "Force refresh"
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Subscribe to git events"
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @topic)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Start polling after a short delay
    Process.send_after(self(), :poll, 2_000)

    {:ok,
     %{
       branch_heads: %{},
       last_updated: nil,
       error: nil,
       poll_in_flight: false
     }}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply,
     %{
       branch_heads: state.branch_heads,
       last_updated: state.last_updated,
       error: state.error
     }, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, %{poll_in_flight: true} = state) do
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    parent = self()
    prev_heads = state.branch_heads

    Task.Supervisor.start_child(DashboardPhoenix.TaskSupervisor, fn ->
      result = poll_git_state(prev_heads)
      send(parent, {:poll_complete, result})
    end)

    {:noreply, %{state | poll_in_flight: true}}
  end

  def handle_info({:poll_complete, {:ok, new_heads, commits}}, state) do
    # Log new commits
    Enum.each(commits, fn commit ->
      log_commit_event(commit)
    end)

    # Broadcast if there were changes
    if commits != [] do
      Phoenix.PubSub.broadcast(
        DashboardPhoenix.PubSub,
        @topic,
        {:git_commits, commits}
      )
    end

    # Schedule next poll
    Process.send_after(self(), :poll, @poll_interval_ms)

    {:noreply,
     %{
       state
       | branch_heads: new_heads,
         last_updated: DateTime.utc_now(),
         error: nil,
         poll_in_flight: false
     }}
  end

  def handle_info({:poll_complete, {:error, reason}}, state) do
    Logger.warning("GitMonitor poll failed: #{inspect(reason)}")
    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, %{state | error: reason, poll_in_flight: false}}
  end

  # Private functions

  defp poll_git_state(prev_heads) do
    with {:ok, base_branch} <- get_base_branch(),
         {:ok, current_head} <- get_branch_head(base_branch) do
      prev_head = Map.get(prev_heads, base_branch)
      new_heads = Map.put(prev_heads, base_branch, current_head)

      commits =
        if prev_head && prev_head != current_head do
          detect_new_commits(prev_head, current_head, base_branch)
        else
          []
        end

      {:ok, new_heads, commits}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_base_branch do
    case CommandRunner.run("git", ["rev-parse", "--verify", "main"],
           cd: repo_path(),
           timeout: @cli_timeout_ms
         ) do
      {:ok, _} ->
        {:ok, "main"}

      _ ->
        case CommandRunner.run("git", ["rev-parse", "--verify", "master"],
               cd: repo_path(),
               timeout: @cli_timeout_ms
             ) do
          {:ok, _} -> {:ok, "master"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp get_branch_head(branch) do
    case CommandRunner.run("git", ["rev-parse", branch],
           cd: repo_path(),
           timeout: @cli_timeout_ms
         ) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp detect_new_commits(old_head, new_head, branch) do
    # Format: hash, subject, author, parent count
    # %P gives all parent hashes, space-separated
    format = "%H||%s||%an||%P"

    case CommandRunner.run("git", ["log", "#{old_head}..#{new_head}", "--format=#{format}"],
           cd: repo_path(),
           timeout: @cli_timeout_ms
         ) do
      {:ok, output} ->
        output
        |> String.split("\n", trim: true)
        # Chronological order
        |> Enum.reverse()
        |> Enum.map(&parse_commit_line(&1, branch))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp parse_commit_line(line, branch) do
    case String.split(line, "||") do
      [hash, message, author, parents] ->
        parent_count = parents |> String.split(" ", trim: true) |> length()
        is_merge = parent_count > 1

        %{
          hash: hash,
          short_hash: String.slice(hash, 0, 7),
          message: String.slice(message, 0, 100),
          author: author,
          branch: branch,
          is_merge: is_merge,
          parent_count: parent_count
        }

      [hash, message, author] ->
        # No parents means initial commit
        %{
          hash: hash,
          short_hash: String.slice(hash, 0, 7),
          message: String.slice(message, 0, 100),
          author: author,
          branch: branch,
          is_merge: false,
          parent_count: 0
        }

      _ ->
        nil
    end
  end

  defp log_commit_event(commit) do
    if commit.is_merge do
      # Merge commit
      ActivityLog.log_event(
        :git_merge,
        "Merge on #{commit.branch}: #{commit.message}",
        %{
          hash: commit.short_hash,
          full_hash: commit.hash,
          message: commit.message,
          author: commit.author,
          branch: commit.branch,
          parent_count: commit.parent_count
        }
      )
    else
      # Regular commit
      ActivityLog.log_event(
        :git_commit,
        "Commit on #{commit.branch}: #{commit.message}",
        %{
          hash: commit.short_hash,
          full_hash: commit.hash,
          message: commit.message,
          author: commit.author,
          branch: commit.branch
        }
      )
    end
  end
end
