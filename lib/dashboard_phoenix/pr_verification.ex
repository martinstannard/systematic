defmodule DashboardPhoenix.PRVerification do
  @moduledoc """
  Manages PR verification status for the dashboard.

  Stores which PRs have been verified by an agent, including when and by whom.
  This allows the dashboard to show a "Verified" badge for PRs that have been
  checked by an agent and found to be clean.

  ## Storage Format

  The verification data is stored in a JSON file (configurable via `Paths.pr_verification_file/0`,
  default: `$OPENCLAW_HOME/pr-verified.json`):

      {
        "verified": {
          "https://github.com/org/repo/pull/123": {
            "verified_at": "2024-01-15T10:30:00Z",
            "verified_by": "subagent-pr-review-123",
            "pr_number": 123,
            "repo": "org/repo",
            "status": "clean"
          }
        }
      }

  ## Usage

  External agents can mark PRs as verified by calling:

      DashboardPhoenix.PRVerification.mark_verified(pr_url, agent_name, opts)

  The dashboard displays verification status in the PR panel with a ✓ badge.
  """

  require Logger

  alias DashboardPhoenix.Paths
  alias DashboardPhoenix.FileUtils

  @topic "pr_verification"

  defp verification_file, do: Paths.pr_verification_file()

  # Client API

  @doc """
  Get verification status for a PR by URL.

  Returns `nil` if not verified, or a map with verification details.
  """
  def get_verification(pr_url) do
    load_verifications()
    |> Map.get(pr_url)
  end

  @doc """
  Get verification status for a PR by number.

  Returns `nil` if not verified, or a map with verification details.
  """
  def get_verification_by_number(pr_number) when is_integer(pr_number) do
    verifications = load_verifications()

    Enum.find_value(verifications, fn {_url, data} ->
      if data["pr_number"] == pr_number, do: data, else: nil
    end)
  end

  @doc """
  Get all verified PRs as a map of URL -> verification data.
  """
  def get_all_verifications do
    load_verifications()
  end

  @doc """
  Mark a PR as verified by an agent.

  Options:
  - :pr_number - The PR number (integer)
  - :repo - The repository (e.g., "Fresh-Clinics/core-platform")
  - :status - Verification status (default: "clean")
  - :notes - Optional notes from the agent
  """
  def mark_verified(pr_url, agent_name, opts \\ []) do
    verifications = load_verifications()

    verification_data = %{
      "verified_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "verified_by" => agent_name,
      "pr_number" => Keyword.get(opts, :pr_number),
      "repo" => Keyword.get(opts, :repo),
      "status" => Keyword.get(opts, :status, "clean"),
      "notes" => Keyword.get(opts, :notes)
    }

    updated = Map.put(verifications, pr_url, verification_data)
    save_verifications(updated)

    # Broadcast update to subscribers
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @topic,
      {:pr_verification_update, updated}
    )

    Logger.info("[PRVerification] Marked PR verified: #{pr_url} by #{agent_name}")

    {:ok, verification_data}
  end

  @doc """
  Remove verification status for a PR.
  """
  def clear_verification(pr_url) do
    verifications = load_verifications()
    updated = Map.delete(verifications, pr_url)
    save_verifications(updated)

    # Broadcast update
    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @topic,
      {:pr_verification_update, updated}
    )

    Logger.info("[PRVerification] Cleared verification for: #{pr_url}")

    :ok
  end

  @doc """
  Clear all verifications. Useful for testing or reset.
  """
  def clear_all do
    save_verifications(%{})

    Phoenix.PubSub.broadcast(
      DashboardPhoenix.PubSub,
      @topic,
      {:pr_verification_update, %{}}
    )

    :ok
  end

  @doc """
  Subscribe to verification updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, @topic)
  end

  @doc """
  Check if a PR is verified (by URL or number).
  """
  def verified?(pr_url) when is_binary(pr_url) do
    get_verification(pr_url) != nil
  end

  def verified?(pr_number) when is_integer(pr_number) do
    get_verification_by_number(pr_number) != nil
  end

  @doc """
  Get the path to the verification file.
  """
  def verification_file_path do
    verification_file()
  end

  # Private functions

  defp load_verifications do
    file = verification_file()

    case File.read(file) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, %{"verified" => verifications}} when is_map(verifications) ->
            verifications

          {:ok, _} ->
            %{}

          {:error, _} ->
            Logger.warning("[PRVerification] Failed to parse verification file, starting fresh")
            %{}
        end

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("[PRVerification] Failed to read verification file: #{inspect(reason)}")
        %{}
    end
  end

  defp save_verifications(verifications) do
    content = Jason.encode!(%{"verified" => verifications}, pretty: true)
    file = verification_file()

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(file))

    case FileUtils.atomic_write(file, content) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("[PRVerification] Failed to save verifications: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
