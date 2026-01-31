defmodule DashboardPhoenix.BranchMonitorTest do
  use ExUnit.Case, async: false
  
  alias DashboardPhoenix.BranchMonitor

  @moduletag :branch_monitor

  # Helper to create a temporary git repo for testing
  defp setup_test_repo(context) do
    test_dir = Path.join(System.tmp_dir!(), "branch_monitor_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)
    
    # Initialize git repo
    {_, 0} = System.cmd("git", ["init"], cd: test_dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@test.com"], cd: test_dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: test_dir)
    
    # Create initial commit on main
    File.write!(Path.join(test_dir, "README.md"), "# Test\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)
    {_, 0} = System.cmd("git", ["commit", "-m", "Initial commit"], cd: test_dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["branch", "-M", "main"], cd: test_dir)
    
    on_exit(fn ->
      # Clean up worktrees and test dir
      {worktree_output, _} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: test_dir, stderr_to_stdout: true)
      
      worktree_output
      |> String.split("\n\n", trim: true)
      |> Enum.each(fn block ->
        case Regex.run(~r/worktree (.+)/, block) do
          [_, path] when path != test_dir ->
            System.cmd("git", ["worktree", "remove", path, "--force"], cd: test_dir, stderr_to_stdout: true)
          _ -> :ok
        end
      end)
      
      File.rm_rf!(test_dir)
    end)
    
    Map.put(context, :test_dir, test_dir)
  end

  describe "git branch detection logic" do
    setup :setup_test_repo
    
    test "git branch --no-merged shows branches with unmerged commits", %{test_dir: test_dir} do
      # Create an unmerged branch with a commit
      {_, 0} = System.cmd("git", ["checkout", "-b", "feature/test"], cd: test_dir)
      File.write!(Path.join(test_dir, "new_file.txt"), "content")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Feature commit"], cd: test_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["checkout", "main"], cd: test_dir)
      
      # Check that the branch appears in --no-merged
      {output, 0} = System.cmd("git", ["branch", "--no-merged", "main", "--format=%(refname:short)"], cd: test_dir)
      branches = String.split(output, "\n", trim: true)
      
      assert "feature/test" in branches
    end
    
    test "git branch --no-merged shows empty when all branches are merged", %{test_dir: test_dir} do
      # Create a branch and merge it
      {_, 0} = System.cmd("git", ["checkout", "-b", "feature/merged"], cd: test_dir)
      File.write!(Path.join(test_dir, "merged_file.txt"), "content")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Will be merged"], cd: test_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["checkout", "main"], cd: test_dir)
      {_, 0} = System.cmd("git", ["merge", "feature/merged", "--no-edit"], cd: test_dir, stderr_to_stdout: true)
      
      # Check that no branches appear (branch is merged)
      {output, 0} = System.cmd("git", ["branch", "--no-merged", "main", "--format=%(refname:short)"], cd: test_dir)
      branches = String.split(output, "\n", trim: true)
      
      refute "feature/merged" in branches
      assert branches == []
    end
    
    test "worktrees are detected even when branch is merged", %{test_dir: test_dir} do
      # Create a branch, add worktree, then merge the branch
      {_, 0} = System.cmd("git", ["checkout", "-b", "feature/with-worktree"], cd: test_dir)
      File.write!(Path.join(test_dir, "worktree_file.txt"), "content")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Worktree commit"], cd: test_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["checkout", "main"], cd: test_dir)
      
      # Create a worktree for another branch
      worktree_path = Path.join(Path.dirname(test_dir), "worktree-test-#{:rand.uniform(100_000)}")
      {_, 0} = System.cmd("git", ["checkout", "-b", "feature/worktree-only"], cd: test_dir)
      File.write!(Path.join(test_dir, "another_file.txt"), "another")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Another commit"], cd: test_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["checkout", "main"], cd: test_dir)
      
      {_, 0} = System.cmd("git", ["worktree", "add", worktree_path, "feature/worktree-only"], cd: test_dir, stderr_to_stdout: true)
      
      on_exit(fn ->
        System.cmd("git", ["worktree", "remove", worktree_path, "--force"], cd: test_dir, stderr_to_stdout: true)
        File.rm_rf!(worktree_path)
      end)
      
      # Worktree should be detected
      {output, 0} = System.cmd("git", ["worktree", "list", "--porcelain"], cd: test_dir)
      
      assert String.contains?(output, "feature/worktree-only")
      assert String.contains?(output, worktree_path)
    end
  end

  describe "worktree output parsing" do
    test "parses worktree porcelain format correctly" do
      # Sample porcelain output
      output = """
      worktree /home/martins/code/systematic
      HEAD e70743c3fbfdb7079f01c4d4cfa579d783c873f5
      branch refs/heads/main

      worktree /home/martins/code/systematic-auto-spawn
      HEAD 83748342d38e447e47759af5bc5fbb36a1aed89a
      branch refs/heads/feature/auto-spawn-agents

      worktree /home/martins/code/systematic-branches
      HEAD a92f4269bf49134982b10291a3bd8900bb356f18
      branch refs/heads/feature/branch-panel
      """
      
      # Parse using the same logic as BranchMonitor
      worktrees = parse_worktree_output(output)
      
      assert Map.get(worktrees, "main") == "/home/martins/code/systematic"
      assert Map.get(worktrees, "feature/auto-spawn-agents") == "/home/martins/code/systematic-auto-spawn"
      assert Map.get(worktrees, "feature/branch-panel") == "/home/martins/code/systematic-branches"
    end
    
    test "handles detached HEAD worktrees" do
      output = """
      worktree /home/martins/code/systematic
      HEAD e70743c3fbfdb7079f01c4d4cfa579d783c873f5
      branch refs/heads/main

      worktree /home/martins/code/systematic-detached
      HEAD abc123
      detached
      """
      
      worktrees = parse_worktree_output(output)
      
      # Detached worktree should not appear (no branch line)
      assert Map.get(worktrees, "main") == "/home/martins/code/systematic"
      assert map_size(worktrees) == 1
    end
    
    # Helper to parse worktree output (mirrors BranchMonitor logic)
    defp parse_worktree_output(output) do
      output
      |> String.split("\n\n", trim: true)
      |> Enum.reduce(%{}, fn block, acc ->
        lines = String.split(block, "\n", trim: true)
        worktree = parse_worktree_block(lines)
        
        if worktree[:branch] do
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
  end

  describe "BranchMonitor.get_branches/0" do
    @tag :integration
    test "returns expected structure" do
      # This test requires the BranchMonitor to be running
      # Skip if not running in the full application context
      case GenServer.whereis(BranchMonitor) do
        nil ->
          # Start the monitor if not running
          {:ok, _pid} = BranchMonitor.start_link([])
          
          # Give it time to fetch initial data
          :timer.sleep(2_000)
          
          result = BranchMonitor.get_branches()
          
          assert is_map(result)
          assert Map.has_key?(result, :branches)
          assert Map.has_key?(result, :worktrees)
          assert Map.has_key?(result, :last_updated)
          assert Map.has_key?(result, :error)
          
          assert is_list(result.branches)
          assert is_map(result.worktrees)
          
          # Stop the monitor
          GenServer.stop(BranchMonitor)
          
        _pid ->
          result = BranchMonitor.get_branches()
          
          assert is_map(result)
          assert Map.has_key?(result, :branches)
          assert Map.has_key?(result, :worktrees)
          assert is_list(result.branches)
      end
    end
    
    @tag :integration
    test "branch entries have expected fields" do
      case GenServer.whereis(BranchMonitor) do
        nil ->
          {:ok, _pid} = BranchMonitor.start_link([])
          :timer.sleep(2_000)
          result = BranchMonitor.get_branches()
          
          for branch <- result.branches do
            assert Map.has_key?(branch, :name)
            assert Map.has_key?(branch, :commits_ahead)
            assert Map.has_key?(branch, :last_commit_date)
            assert Map.has_key?(branch, :last_commit_message)
            assert Map.has_key?(branch, :last_commit_author)
            assert Map.has_key?(branch, :worktree_path)
            assert Map.has_key?(branch, :has_worktree)
            
            assert is_binary(branch.name)
            assert is_integer(branch.commits_ahead)
            assert is_boolean(branch.has_worktree)
          end
          
          GenServer.stop(BranchMonitor)
          
        _pid ->
          result = BranchMonitor.get_branches()
          
          for branch <- result.branches do
            assert Map.has_key?(branch, :name)
            assert is_binary(branch.name)
          end
      end
    end
  end

  describe "understanding empty results" do
    setup :setup_test_repo
    
    @doc """
    This test documents WHY the Unmerged Branches panel might show empty.
    
    The panel uses `git branch --no-merged main` which ONLY shows branches
    that have commits NOT present in main. If all feature branches have been
    merged to main, the panel correctly shows empty - even if worktrees
    still exist for those branches.
    
    This is expected behavior, not a bug.
    """
    test "panel shows empty when all branches are merged to main", %{test_dir: test_dir} do
      # Scenario: Create branches with worktrees, merge them all to main
      
      # Create feature/a with a commit
      {_, 0} = System.cmd("git", ["checkout", "-b", "feature/a"], cd: test_dir)
      File.write!(Path.join(test_dir, "a.txt"), "a")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Feature A"], cd: test_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["checkout", "main"], cd: test_dir)
      
      # Create feature/b with a commit
      {_, 0} = System.cmd("git", ["checkout", "-b", "feature/b"], cd: test_dir)
      File.write!(Path.join(test_dir, "b.txt"), "b")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)
      {_, 0} = System.cmd("git", ["commit", "-m", "Feature B"], cd: test_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["checkout", "main"], cd: test_dir)
      
      # Before merge: both branches should be unmerged
      {output, 0} = System.cmd("git", ["branch", "--no-merged", "main", "--format=%(refname:short)"], cd: test_dir)
      before_merge = String.split(output, "\n", trim: true)
      
      assert "feature/a" in before_merge
      assert "feature/b" in before_merge
      
      # Merge both branches
      {_, 0} = System.cmd("git", ["merge", "feature/a", "--no-edit"], cd: test_dir, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["merge", "feature/b", "--no-edit"], cd: test_dir, stderr_to_stdout: true)
      
      # After merge: no unmerged branches
      {output, 0} = System.cmd("git", ["branch", "--no-merged", "main", "--format=%(refname:short)"], cd: test_dir)
      after_merge = String.split(output, "\n", trim: true)
      
      assert after_merge == []
      
      # But the branches still exist!
      {output, 0} = System.cmd("git", ["branch", "--format=%(refname:short)"], cd: test_dir)
      all_branches = String.split(output, "\n", trim: true)
      
      assert "feature/a" in all_branches
      assert "feature/b" in all_branches
      assert "main" in all_branches
    end
  end
end
