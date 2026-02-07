defmodule DashboardPhoenix.PRMonitorTest do
  use ExUnit.Case, async: true

  alias DashboardPhoenix.PRMonitor

  # Tests for parsing logic - we test via implementations that mirror
  # the private function logic

  describe "parse_ci_status/1 logic" do
    test "returns :unknown for nil" do
      assert parse_ci_status(nil) == :unknown
    end

    test "returns :unknown for empty list" do
      assert parse_ci_status([]) == :unknown
    end

    test "returns :success when all checks pass" do
      checks = [
        %{"conclusion" => "SUCCESS"},
        %{"conclusion" => "SUCCESS"},
        %{"conclusion" => "SUCCESS"}
      ]

      assert parse_ci_status(checks) == :success
    end

    test "returns :failure when any check fails" do
      checks = [
        %{"conclusion" => "SUCCESS"},
        %{"conclusion" => "FAILURE"},
        %{"conclusion" => "SUCCESS"}
      ]

      assert parse_ci_status(checks) == :failure
    end

    test "returns :pending when any check is in progress" do
      checks = [
        %{"conclusion" => "SUCCESS"},
        # nil means in progress
        %{"conclusion" => nil},
        %{"conclusion" => "SUCCESS"}
      ]

      assert parse_ci_status(checks) == :pending
    end

    test "failure takes precedence over pending" do
      checks = [
        %{"conclusion" => "SUCCESS"},
        %{"conclusion" => nil},
        %{"conclusion" => "FAILURE"}
      ]

      assert parse_ci_status(checks) == :failure
    end

    test "handles NEUTRAL conclusion" do
      checks = [
        %{"conclusion" => "NEUTRAL"}
      ]

      # Neutral alone doesn't constitute success
      assert parse_ci_status(checks) == :unknown
    end
  end

  describe "parse_review_status/1 logic" do
    test "returns :pending for nil" do
      assert parse_review_status(nil) == :pending
    end

    test "returns :pending for empty list" do
      assert parse_review_status([]) == :pending
    end

    test "returns :approved when approved" do
      reviews = [
        %{"state" => "APPROVED", "author" => %{"login" => "reviewer1"}}
      ]

      assert parse_review_status(reviews) == :approved
    end

    test "returns :changes_requested when changes requested" do
      reviews = [
        %{"state" => "CHANGES_REQUESTED", "author" => %{"login" => "reviewer1"}}
      ]

      assert parse_review_status(reviews) == :changes_requested
    end

    test "changes_requested takes precedence over approved" do
      reviews = [
        %{"state" => "APPROVED", "author" => %{"login" => "reviewer1"}},
        %{"state" => "CHANGES_REQUESTED", "author" => %{"login" => "reviewer2"}}
      ]

      assert parse_review_status(reviews) == :changes_requested
    end

    test "uses latest review per author" do
      reviews = [
        %{"state" => "CHANGES_REQUESTED", "author" => %{"login" => "reviewer1"}},
        # Same author, approved later
        %{"state" => "APPROVED", "author" => %{"login" => "reviewer1"}}
      ]

      # Latest review from reviewer1 is APPROVED
      assert parse_review_status(reviews) == :approved
    end

    test "returns :commented when only comments exist" do
      reviews = [
        %{"state" => "COMMENTED", "author" => %{"login" => "reviewer1"}}
      ]

      assert parse_review_status(reviews) == :commented
    end
  end

  describe "extract_ticket_ids/1 logic" do
    test "extracts COR ticket IDs" do
      text = "COR-123 Fix the login bug"
      assert extract_ticket_ids(text) == ["COR-123"]
    end

    test "extracts FRE ticket IDs" do
      text = "FRE-456 New feature"
      assert extract_ticket_ids(text) == ["FRE-456"]
    end

    test "extracts multiple ticket IDs" do
      text = "COR-123 and FRE-456 together"
      ids = extract_ticket_ids(text)
      assert "COR-123" in ids
      assert "FRE-456" in ids
    end

    test "handles case insensitivity and normalizes to uppercase" do
      text = "cor-123 lowercase id"
      assert extract_ticket_ids(text) == ["COR-123"]
    end

    test "returns empty list when no ticket IDs found" do
      text = "Just a regular title"
      assert extract_ticket_ids(text) == []
    end

    test "deduplicates ticket IDs" do
      text = "COR-123 mentioned twice COR-123"
      assert extract_ticket_ids(text) == ["COR-123"]
    end
  end

  describe "parse_datetime/1 logic" do
    test "parses valid ISO8601 datetime" do
      result = parse_datetime("2024-01-15T10:30:00Z")
      assert %DateTime{} = result
      assert result.year == 2024
      assert result.month == 1
      assert result.day == 15
    end

    test "returns nil for nil input" do
      assert parse_datetime(nil) == nil
    end

    test "returns nil for invalid datetime string" do
      assert parse_datetime("not a date") == nil
    end

    test "returns nil for non-string input" do
      assert parse_datetime(12345) == nil
    end
  end

  describe "parse_pr/2 logic" do
    test "parses complete PR data" do
      pr_data = %{
        "number" => 42,
        "title" => "COR-123 Fix login bug",
        "state" => "OPEN",
        "headRefName" => "feature/cor-123-login-fix",
        "url" => "https://github.com/org/repo/pull/42",
        "author" => %{"login" => "developer"},
        "createdAt" => "2024-01-15T10:00:00Z",
        "mergeable" => "MERGEABLE",
        "statusCheckRollup" => [%{"conclusion" => "SUCCESS"}],
        "reviews" => []
      }

      result = parse_pr(pr_data, "org/repo")

      assert result.number == 42
      assert result.title == "COR-123 Fix login bug"
      assert result.state == "OPEN"
      assert result.branch == "feature/cor-123-login-fix"
      assert result.url == "https://github.com/org/repo/pull/42"
      assert result.repo == "org/repo"
      assert result.author == "developer"
      assert "COR-123" in result.ticket_ids
      assert result.ci_status == :success
      assert result.review_status == :pending
      assert result.has_conflicts == false
    end

    test "detects merge conflicts" do
      pr_data = %{
        "number" => 1,
        "title" => "Test",
        "state" => "OPEN",
        "headRefName" => "test-branch",
        "url" => "https://github.com/test/test/pull/1",
        "mergeable" => "CONFLICTING"
      }

      result = parse_pr(pr_data, "test/test")
      assert result.has_conflicts == true
    end

    test "handles missing author" do
      pr_data = %{
        "number" => 1,
        "title" => "Test",
        "state" => "OPEN",
        "headRefName" => "test-branch",
        "url" => "https://github.com/test/test/pull/1"
      }

      result = parse_pr(pr_data, "test/test")
      assert result.author == "unknown"
    end
  end

  describe "build_ticket_url/1" do
    test "builds correct Linear URL" do
      url = PRMonitor.build_ticket_url("COR-123")
      assert url == "https://linear.app/fresh-clinics/issue/COR-123"
    end

    test "works with different ticket IDs" do
      url = PRMonitor.build_ticket_url("FRE-456")
      assert url == "https://linear.app/fresh-clinics/issue/FRE-456"
    end
  end

  describe "GenServer behavior" do
    test "module exports expected client API functions" do
      assert function_exported?(PRMonitor, :start_link, 1)
      assert function_exported?(PRMonitor, :get_prs, 0)
      assert function_exported?(PRMonitor, :refresh, 0)
      assert function_exported?(PRMonitor, :subscribe, 0)
    end

    # Note: Ticket #71 - init creates ETS table, can't test directly without conflicts
    test "get_prs returns expected structure (ETS-based)" do
      # The monitor is started as part of the application
      # Just verify the public API returns the expected structure
      result = PRMonitor.get_prs()

      assert is_map(result)
      assert is_list(result.prs)
      assert Map.has_key?(result, :last_updated)
      assert Map.has_key?(result, :error)
    end

    test "handle_cast :refresh sends poll message" do
      state = %{prs: [], last_updated: nil, error: nil}

      {:noreply, new_state} = PRMonitor.handle_cast(:refresh, state)

      assert_receive :poll, 100
      assert new_state == state
    end
  end

  # Implementations mirroring the private function logic
  defp parse_ci_status(nil), do: :unknown
  defp parse_ci_status([]), do: :unknown

  defp parse_ci_status(checks) when is_list(checks) do
    statuses =
      Enum.map(checks, fn check ->
        case Map.get(check, "conclusion") do
          "SUCCESS" -> :success
          "FAILURE" -> :failure
          "NEUTRAL" -> :neutral
          nil -> :pending
          _ -> :unknown
        end
      end)

    cond do
      Enum.any?(statuses, &(&1 == :failure)) -> :failure
      Enum.any?(statuses, &(&1 == :pending)) -> :pending
      Enum.all?(statuses, &(&1 == :success)) -> :success
      true -> :unknown
    end
  end

  defp parse_ci_status(_), do: :unknown

  defp parse_review_status(nil), do: :pending
  defp parse_review_status([]), do: :pending

  defp parse_review_status(reviews) when is_list(reviews) do
    latest_by_author =
      reviews
      |> Enum.group_by(&get_in(&1, ["author", "login"]))
      |> Enum.map(fn {_author, author_reviews} -> List.last(author_reviews) end)
      |> Enum.map(&Map.get(&1, "state"))

    cond do
      Enum.any?(latest_by_author, &(&1 == "CHANGES_REQUESTED")) -> :changes_requested
      Enum.any?(latest_by_author, &(&1 == "APPROVED")) -> :approved
      Enum.any?(latest_by_author, &(&1 == "COMMENTED")) -> :commented
      true -> :pending
    end
  end

  defp parse_review_status(_), do: :pending

  defp extract_ticket_ids(text) do
    ~r/(COR|FRE)-\d+/i
    |> Regex.scan(text)
    |> Enum.map(fn [full_match | _] -> String.upcase(full_match) end)
    |> Enum.uniq()
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(datetime_str) when is_binary(datetime_str) do
    case DateTime.from_iso8601(datetime_str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp parse_pr(pr_data, repo) do
    title = Map.get(pr_data, "title", "")
    branch = Map.get(pr_data, "headRefName", "")
    ticket_ids = extract_ticket_ids("#{title} #{branch}")
    ci_status = parse_ci_status(Map.get(pr_data, "statusCheckRollup"))
    review_status = parse_review_status(Map.get(pr_data, "reviews", []))
    has_conflicts = Map.get(pr_data, "mergeable") == "CONFLICTING"

    %{
      number: Map.get(pr_data, "number"),
      title: title,
      state: Map.get(pr_data, "state"),
      branch: branch,
      url: Map.get(pr_data, "url"),
      repo: repo,
      author: get_in(pr_data, ["author", "login"]) || "unknown",
      created_at: parse_datetime(Map.get(pr_data, "createdAt")),
      ci_status: ci_status,
      review_status: review_status,
      ticket_ids: ticket_ids,
      has_conflicts: has_conflicts
    }
  end
end
