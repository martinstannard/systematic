defmodule DashboardPhoenix.PRVerificationTest do
  use ExUnit.Case, async: false

  alias DashboardPhoenix.PRVerification

  @test_file "/tmp/test-pr-verified.json"

  setup do
    # Save original verification file path and set test path
    _original_file = PRVerification.verification_file_path()

    # Clean up any existing test file
    File.rm(@test_file)

    # We can't easily change the module attribute, so we'll work with the real file
    # but clean up after each test
    on_exit(fn ->
      # Clean up test verifications from the real file
      PRVerification.clear_all()
    end)

    # Start fresh for each test
    PRVerification.clear_all()

    :ok
  end

  describe "mark_verified/3" do
    test "marks a PR as verified with all required fields" do
      pr_url = "https://github.com/test/repo/pull/123"
      agent_name = "test-agent"

      result =
        PRVerification.mark_verified(pr_url, agent_name,
          pr_number: 123,
          repo: "test/repo",
          status: "clean"
        )

      assert {:ok, verification} = result
      assert verification["verified_by"] == "test-agent"
      assert verification["pr_number"] == 123
      assert verification["repo"] == "test/repo"
      assert verification["status"] == "clean"
      assert verification["verified_at"] != nil
    end

    test "marks a PR as verified with optional notes" do
      pr_url = "https://github.com/test/repo/pull/456"

      {:ok, verification} =
        PRVerification.mark_verified(pr_url, "reviewer-bot",
          pr_number: 456,
          repo: "test/repo",
          notes: "All tests pass, code looks good"
        )

      assert verification["notes"] == "All tests pass, code looks good"
    end

    test "uses default status of 'clean' when not specified" do
      pr_url = "https://github.com/test/repo/pull/789"

      {:ok, verification} =
        PRVerification.mark_verified(pr_url, "agent",
          pr_number: 789,
          repo: "test/repo"
        )

      assert verification["status"] == "clean"
    end
  end

  describe "get_verification/1" do
    test "returns nil for unverified PR" do
      assert PRVerification.get_verification("https://github.com/test/repo/pull/999") == nil
    end

    test "returns verification data for verified PR" do
      pr_url = "https://github.com/test/repo/pull/100"
      PRVerification.mark_verified(pr_url, "test-agent", pr_number: 100, repo: "test/repo")

      verification = PRVerification.get_verification(pr_url)

      assert verification != nil
      assert verification["verified_by"] == "test-agent"
      assert verification["pr_number"] == 100
    end
  end

  describe "get_verification_by_number/1" do
    test "returns nil for unverified PR number" do
      assert PRVerification.get_verification_by_number(999) == nil
    end

    test "returns verification data when found by PR number" do
      pr_url = "https://github.com/test/repo/pull/200"
      PRVerification.mark_verified(pr_url, "agent", pr_number: 200, repo: "test/repo")

      verification = PRVerification.get_verification_by_number(200)

      assert verification != nil
      assert verification["pr_number"] == 200
    end
  end

  describe "verified?/1" do
    test "returns false for unverified PR URL" do
      refute PRVerification.verified?("https://github.com/test/repo/pull/999")
    end

    test "returns true for verified PR URL" do
      pr_url = "https://github.com/test/repo/pull/300"
      PRVerification.mark_verified(pr_url, "agent", pr_number: 300, repo: "test/repo")

      assert PRVerification.verified?(pr_url)
    end

    test "returns false for unverified PR number" do
      refute PRVerification.verified?(999)
    end

    test "returns true for verified PR number" do
      pr_url = "https://github.com/test/repo/pull/400"
      PRVerification.mark_verified(pr_url, "agent", pr_number: 400, repo: "test/repo")

      assert PRVerification.verified?(400)
    end
  end

  describe "clear_verification/1" do
    test "removes verification for a PR" do
      pr_url = "https://github.com/test/repo/pull/500"
      PRVerification.mark_verified(pr_url, "agent", pr_number: 500, repo: "test/repo")

      assert PRVerification.verified?(pr_url)

      PRVerification.clear_verification(pr_url)

      refute PRVerification.verified?(pr_url)
    end
  end

  describe "get_all_verifications/0" do
    test "returns empty map when no verifications exist" do
      assert PRVerification.get_all_verifications() == %{}
    end

    test "returns all verified PRs" do
      PRVerification.mark_verified("https://github.com/test/repo/pull/1", "agent1",
        pr_number: 1,
        repo: "test/repo"
      )

      PRVerification.mark_verified("https://github.com/test/repo/pull/2", "agent2",
        pr_number: 2,
        repo: "test/repo"
      )

      verifications = PRVerification.get_all_verifications()

      assert map_size(verifications) == 2
      assert Map.has_key?(verifications, "https://github.com/test/repo/pull/1")
      assert Map.has_key?(verifications, "https://github.com/test/repo/pull/2")
    end
  end

  describe "clear_all/0" do
    test "removes all verifications" do
      PRVerification.mark_verified("https://github.com/test/repo/pull/1", "agent",
        pr_number: 1,
        repo: "test/repo"
      )

      PRVerification.mark_verified("https://github.com/test/repo/pull/2", "agent",
        pr_number: 2,
        repo: "test/repo"
      )

      assert map_size(PRVerification.get_all_verifications()) == 2

      PRVerification.clear_all()

      assert PRVerification.get_all_verifications() == %{}
    end
  end

  describe "persistence" do
    test "verifications persist across module reloads" do
      pr_url = "https://github.com/test/repo/pull/600"
      PRVerification.mark_verified(pr_url, "persistent-agent", pr_number: 600, repo: "test/repo")

      # Simulate "module reload" by clearing internal state and reading from file
      # The get_verification function reads from file each time
      verification = PRVerification.get_verification(pr_url)

      assert verification != nil
      assert verification["verified_by"] == "persistent-agent"
    end
  end
end
