defmodule DashboardPhoenix.BranchMonitor do
  @moduledoc """
  Monitors local git branches that have commits not yet merged to main.
  Provides visibility into work-in-progress branches and associated worktrees.
  """

  use GenServer
  require Logger

  @poll_interval_ms 120_000  # 2 minutes
  @topic "branch_updates"
  @repo_path Path.expand("~/code/systematic")

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get all cached unmerged branches"
  def get_branches do
    GenServer.call(__MODULE__, :get_branches)
  end

  @doc "Force refresh branches"
  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  @doc "Subscribe to branch updates"
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @topic)
  end

  @doc "Merge a branch to main"
  def merge_branch(branch_name) do
    GenServer.call(__MODULE__, {:merge_branch, branch_name}, 30_000)
  end

  @doc "Delete a branch"
  def delete_branch(branch_name) do
    GenServer.call(__MODULE__, {:delete_branch, branch_name}, 30_000)
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    # Start polling after a short delay
    Process.send_after(self(), :poll, 1_000)
    {:ok, %{branches: [], worktrees: %{}, last_updated: nil, error: nil}}
  end

  @impl true
  def handle_call(:get_branches, _from, state) do
    {:reply, %{
      branches: state.branches,
      worktrees: state.worktrees,
      last_updated: state.last_updated,
      error: state.error
    }, state}
  end

  @impl true
  def handle_call({:merge_branch, branch_name}, _from, state) do
    result = do_merge_branch(branch_name)
    
    # Refresh after merge attempt
    send(self(), :poll)
    
    {:reply, result, state}
  end

  @impl true
  def handle_call({:delete_branch, branch_name}, _from, state) do
    result = do_delete_branch(branch_name)
    
    # Refresh after delete attempt
    send(self(), :poll)
    
    {:reply, result, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = fetch_branches(state)
    
    # Broadcast update to subscribers
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @topic,
      {:branch_update, %{
        branches: new_state.branches,
        worktrees: new_state.worktrees,
        last_updated: new_state.last_updated,
        error: new_state.error
      }}
    )
    
    # Schedule next poll
    Process.send_after(self(), :poll, @poll_interval_ms)
    
    {:noreply, new_state}
  end

  # Private functions

  defp fetch_branches(state) do
    with {:ok, worktrees} <- fetch_worktrees(),
         {:ok, unmerged} <- fetch_unmerged_branches(),
         {:ok, branches} <- enrich_branches(unmerged, worktrees) do
      %{state |
        branches: branches,
        worktrees: worktrees,
        last_updated: DateTime.utc_now(),
        error: nil
      }
    else
      {:error, reason} ->
        Logger.error("Failed to fetch branches: #{inspect(reason)}")
        %{state | error: "Failed to fetch branches: #{reason}"}
    end
  rescue
    e ->
      Logger.error("Exception fetching branches: #{inspect(e)}")
      %{state | error: "Exception: #{Exception.message(e)}"}
  end

  defp fetch_worktrees do
    case System.cmd("git", ["worktree", "list", "--porcelain"], cd: @repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        worktrees = parse_worktree_output(output)
        {:ok, worktrees}
      
      {error, _code} ->
        Logger.warning("git worktree list failed: #{error}")
        {:ok, %{}}  # Return empty map on error, don't fail completely
    end
  end

  defp parse_worktree_output(output) do
    output
    |> String.split("\n\n", trim: true)
    |> Enum.reduce(%{}, fn block, acc ->
      lines = String.split(block, "\n", trim: true)
      worktree = parse_worktree_block(lines)
      
      if worktree[:branch] do
        # Strip refs/heads/ prefix
        branch = worktree[:branch]
        |> String.replace_prefix("refs/heads/", "")
        
        Map.put(acc, branch, worktree[:path])
      else
        acc
      end
    end)
  end

  defp parse_worktree_block(lines) do
    Enum.reduce(lines, %{}, fn line, acc ->
      cond do
        String.starts_with?(line, "worktree ") ->
          Map.put(acc, :path, String.replace_prefix(line, "worktree ", ""))
        
        String.starts_with?(line, "branch ") ->
          Map.put(acc, :branch, String.replace_prefix(line, "branch ", ""))
        
        true ->
          acc
      end
    end)
  end

  defp fetch_unmerged_branches do
    case System.cmd("git", ["branch", "--no-merged", "main", "--format=%(refname:short)"], 
                    cd: @repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        branches = output
        |> String.split("\n", trim: true)
        |> Enum.reject(&(&1 == "" or &1 == "main"))
        
        {:ok, branches}
      
      {error, code} ->
        # If main doesn't exist, try master
        if code != 0 and String.contains?(error, "main") do
          case System.cmd("git", ["branch", "--no-merged", "master", "--format=%(refname:short)"],
                          cd: @repo_path, stderr_to_stdout: true) do
            {output, 0} ->
              branches = output
              |> String.split("\n", trim: true)
              |> Enum.reject(&(&1 == "" or &1 == "master"))
              
              {:ok, branches}
            
            {err, _} ->
              {:error, err}
          end
        else
          {:error, error}
        end
    end
  end

  defp enrich_branches(branch_names, worktrees) do
    branches = Enum.map(branch_names, fn name ->
      with {:ok, commits_ahead} <- get_commits_ahead(name),
           {:ok, last_commit} <- get_last_commit(name) do
        %{
          name: name,
          commits_ahead: commits_ahead,
          last_commit_date: last_commit[:date],
          last_commit_message: last_commit[:message],
          last_commit_author: last_commit[:author],
          worktree_path: Map.get(worktrees, name),
          has_worktree: Map.has_key?(worktrees, name)
        }
      else
        {:error, _reason} ->
          %{
            name: name,
            commits_ahead: 0,
            last_commit_date: nil,
            last_commit_message: nil,
            last_commit_author: nil,
            worktree_path: Map.get(worktrees, name),
            has_worktree: Map.has_key?(worktrees, name)
          }
      end
    end)
    
    # Sort by last commit date (newest first)
    sorted = Enum.sort_by(branches, fn b ->
      case b.last_commit_date do
        %DateTime{} = dt -> {0, -DateTime.to_unix(dt)}
        _ -> {1, 0}
      end
    end)
    
    {:ok, sorted}
  end

  defp get_commits_ahead(branch_name) do
    # Try main first, then master
    base_branch = get_base_branch()
    
    case System.cmd("git", ["rev-list", "--count", "#{base_branch}..#{branch_name}"],
                    cd: @repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        count = output |> String.trim() |> String.to_integer()
        {:ok, count}
      
      {error, _code} ->
        Logger.warning("Failed to get commits ahead for #{branch_name}: #{error}")
        {:error, error}
    end
  end

  defp get_last_commit(branch_name) do
    format = "%aI||%s||%an"  # ISO date, subject, author name
    
    case System.cmd("git", ["log", "-1", "--format=#{format}", branch_name],
                    cd: @repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        case String.split(String.trim(output), "||") do
          [date_str, message, author] ->
            date = case DateTime.from_iso8601(date_str) do
              {:ok, dt, _offset} -> dt
              _ -> nil
            end
            
            {:ok, %{date: date, message: String.slice(message, 0, 80), author: author}}
          
          _ ->
            {:error, "Unexpected log format"}
        end
      
      {error, _code} ->
        {:error, error}
    end
  end

  defp get_base_branch do
    # Check if main exists
    case System.cmd("git", ["rev-parse", "--verify", "main"],
                    cd: @repo_path, stderr_to_stdout: true) do
      {_, 0} -> "main"
      _ -> "master"
    end
  end

  defp do_merge_branch(branch_name) do
    base_branch = get_base_branch()
    
    # First, checkout main/master
    case System.cmd("git", ["checkout", base_branch], cd: @repo_path, stderr_to_stdout: true) do
      {_, 0} ->
        # Then merge the branch
        case System.cmd("git", ["merge", branch_name, "--no-edit"], cd: @repo_path, stderr_to_stdout: true) do
          {output, 0} ->
            Logger.info("Successfully merged #{branch_name} to #{base_branch}")
            {:ok, output}
          
          {error, _code} ->
            # Abort the merge if it failed
            System.cmd("git", ["merge", "--abort"], cd: @repo_path, stderr_to_stdout: true)
            Logger.error("Failed to merge #{branch_name}: #{error}")
            {:error, "Merge failed: #{String.slice(error, 0, 200)}"}
        end
      
      {error, _code} ->
        Logger.error("Failed to checkout #{base_branch}: #{error}")
        {:error, "Failed to checkout #{base_branch}: #{String.slice(error, 0, 200)}"}
    end
  end

  defp do_delete_branch(branch_name) do
    # Check if branch has a worktree
    case fetch_worktrees() do
      {:ok, worktrees} ->
        if Map.has_key?(worktrees, branch_name) do
          worktree_path = Map.get(worktrees, branch_name)
          
          # Remove worktree first
          case System.cmd("git", ["worktree", "remove", worktree_path, "--force"],
                          cd: @repo_path, stderr_to_stdout: true) do
            {_, 0} ->
              Logger.info("Removed worktree at #{worktree_path}")
              delete_branch_ref(branch_name)
            
            {error, _code} ->
              Logger.error("Failed to remove worktree: #{error}")
              {:error, "Failed to remove worktree: #{String.slice(error, 0, 200)}"}
          end
        else
          delete_branch_ref(branch_name)
        end
      
      {:error, reason} ->
        {:error, "Failed to check worktrees: #{reason}"}
    end
  end

  defp delete_branch_ref(branch_name) do
    # Delete the branch (force delete to allow unmerged branches)
    case System.cmd("git", ["branch", "-D", branch_name], cd: @repo_path, stderr_to_stdout: true) do
      {output, 0} ->
        Logger.info("Deleted branch #{branch_name}")
        {:ok, output}
      
      {error, _code} ->
        Logger.error("Failed to delete branch #{branch_name}: #{error}")
        {:error, "Failed to delete: #{String.slice(error, 0, 200)}"}
    end
  end
end
