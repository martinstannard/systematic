defmodule DashboardPhoenix.GitMonitorTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.{ActivityLog, GitMonitor}

  @moduletag :git_monitor

  # Helper to create a temporary git repo for testing
  defp setup_test_repo(context) do
    test_dir = Path.join(System.tmp_dir!(), "git_monitor_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(test_dir)

    # Initialize git repo
    {_, 0} = System.cmd("git", ["init"], cd: test_dir, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@test.com"], cd: test_dir)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test Author"], cd: test_dir)

    # Create initial commit on main
    File.write!(Path.join(test_dir, "README.md"), "# Test\n")
    {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)

    {_, 0} =
      System.cmd("git", ["commit", "-m", "Initial commit"], cd: test_dir, stderr_to_stdout: true)

    {_, 0} = System.cmd("git", ["branch", "-M", "main"], cd: test_dir)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    Map.put(context, :test_dir, test_dir)
  end

  describe "commit detection logic" do
    setup :setup_test_repo

    test "detects regular commits", %{test_dir: test_dir} do
      # Get initial HEAD
      {initial_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: test_dir)
      initial_head = String.trim(initial_head)

      # Create a new commit
      File.write!(Path.join(test_dir, "new_file.txt"), "content")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)

      {_, 0} =
        System.cmd("git", ["commit", "-m", "Add new file"], cd: test_dir, stderr_to_stdout: true)

      # Get new HEAD
      {new_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: test_dir)
      new_head = String.trim(new_head)

      # Get commits between old and new HEAD
      {output, 0} =
        System.cmd("git", ["log", "#{initial_head}..#{new_head}", "--format=%H||%s||%an||%P"],
          cd: test_dir
        )

      commits = String.split(output, "\n", trim: true)
      assert length(commits) == 1

      [commit_line] = commits
      [hash, message, author, parents] = String.split(commit_line, "||")

      assert String.length(hash) == 40
      assert message == "Add new file"
      assert author == "Test Author"
      # Regular commit has exactly 1 parent
      assert length(String.split(parents, " ", trim: true)) == 1
    end

    test "detects merge commits (multiple parents)", %{test_dir: test_dir} do
      # Create a branch with a commit
      {_, 0} = System.cmd("git", ["checkout", "-b", "feature"], cd: test_dir)
      File.write!(Path.join(test_dir, "feature.txt"), "feature content")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)

      {_, 0} =
        System.cmd("git", ["commit", "-m", "Add feature"], cd: test_dir, stderr_to_stdout: true)

      # Go back to main and create a different commit
      {_, 0} = System.cmd("git", ["checkout", "main"], cd: test_dir)
      File.write!(Path.join(test_dir, "main_change.txt"), "main content")
      {_, 0} = System.cmd("git", ["add", "."], cd: test_dir)

      {_, 0} =
        System.cmd("git", ["commit", "-m", "Main change"], cd: test_dir, stderr_to_stdout: true)

      # Get HEAD before merge
      {pre_merge_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: test_dir)
      pre_merge_head = String.trim(pre_merge_head)

      # Merge the feature branch (creates a merge commit)
      {_, 0} =
        System.cmd("git", ["merge", "feature", "--no-ff", "-m", "Merge feature branch"],
          cd: test_dir,
          stderr_to_stdout: true
        )

      # Get new HEAD
      {new_head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: test_dir)
      new_head = String.trim(new_head)

      # Get the merge commit
      {output, 0} =
        System.cmd("git", ["log", "#{pre_merge_head}..#{new_head}", "--format=%H||%s||%an||%P"],
          cd: test_dir
        )

      commits = String.split(output, "\n", trim: true)
      assert length(commits) >= 1

      # Find the merge commit (the one with multiple parents)
      merge_commit =
        Enum.find(commits, fn line ->
          [_hash, _message, _author, parents] = String.split(line, "||")
          length(String.split(parents, " ", trim: true)) > 1
        end)

      assert merge_commit != nil
      [_hash, message, _author, parents] = String.split(merge_commit, "||")
      assert message == "Merge feature branch"
      assert length(String.split(parents, " ", trim: true)) == 2
    end
  end

  describe "GitMonitor module" do
    test "exports expected client API functions" do
      assert function_exported?(GitMonitor, :start_link, 1)
      assert function_exported?(GitMonitor, :get_state, 0)
      assert function_exported?(GitMonitor, :refresh, 0)
      assert function_exported?(GitMonitor, :subscribe, 0)
    end
  end

  describe "ActivityLog git event types" do
    setup do
      ActivityLog.clear()
      :ok
    end

    test "accepts git_commit event type" do
      {:ok, event} =
        ActivityLog.log_event(:git_commit, "Commit on main: Add feature", %{
          hash: "abc1234",
          full_hash: "abc1234567890abcdef1234567890abcdef123456",
          message: "Add feature",
          author: "Test Author",
          branch: "main"
        })

      assert event.type == :git_commit
      assert event.message == "Commit on main: Add feature"
      assert event.details.hash == "abc1234"
      assert event.details.author == "Test Author"
    end

    test "accepts git_merge event type" do
      {:ok, event} =
        ActivityLog.log_event(:git_merge, "Merge on main: Merge feature branch", %{
          hash: "def5678",
          full_hash: "def5678901234567890abcdef1234567890abcdef",
          message: "Merge feature branch",
          author: "Test Author",
          branch: "main",
          parent_count: 2
        })

      assert event.type == :git_merge
      assert event.message == "Merge on main: Merge feature branch"
      assert event.details.hash == "def5678"
      assert event.details.parent_count == 2
    end

    test "git event types are in valid_event_types" do
      types = ActivityLog.valid_event_types()
      assert :git_commit in types
      assert :git_merge in types
    end
  end

  describe "commit parsing" do
    test "parses regular commit line correctly" do
      line =
        "abc1234567890abcdef1234567890abcdef123456||Add new feature||John Doe||parent1234567890abcdef1234567890abcdef12"

      [hash, message, author, parents] = String.split(line, "||")
      parent_list = String.split(parents, " ", trim: true)

      assert hash == "abc1234567890abcdef1234567890abcdef123456"
      assert message == "Add new feature"
      assert author == "John Doe"
      assert length(parent_list) == 1
    end

    test "parses merge commit line correctly" do
      line =
        "abc1234567890abcdef1234567890abcdef123456||Merge branch 'feature'||John Doe||parent1234567890abcdef1234567890abcdef12 parent2234567890abcdef1234567890abcdef12"

      [hash, message, author, parents] = String.split(line, "||")
      parent_list = String.split(parents, " ", trim: true)

      assert hash == "abc1234567890abcdef1234567890abcdef123456"
      assert message == "Merge branch 'feature'"
      assert author == "John Doe"
      assert length(parent_list) == 2
    end
  end
end
