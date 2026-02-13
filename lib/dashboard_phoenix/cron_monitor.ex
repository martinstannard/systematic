defmodule DashboardPhoenix.CronMonitor do
  @moduledoc """
  Monitors OpenClaw cron jobs status by querying the gateway.

  Fetches cron job data including:
  - Job name, schedule, and enabled status
  - Last run status (ok/error/running)
  - Last run timestamp and duration
  - Next scheduled run time
  - Consecutive error count
  """

  require Logger
  alias DashboardPhoenix.CommandRunner

  @doc """
  Fetches all cron jobs from the OpenClaw gateway.

  Returns `{:ok, jobs}` on success or `{:error, reason}` on failure.
  """
  @spec fetch_cron_jobs() :: {:ok, list(map())} | {:error, String.t()}
  def fetch_cron_jobs do
    case CommandRunner.run("openclaw", ["cron", "list", "--json"], timeout: 10_000) do
      {:ok, output} ->
        parse_cron_output(output)

      {:error, :timeout} ->
        {:error, "Timeout fetching cron jobs"}

      {:error, {_exit_code, error_output}} ->
        {:error, "Failed to fetch cron jobs: #{error_output}"}

      {:error, reason} ->
        {:error, "Failed to fetch cron jobs: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("[CronMonitor] Exception fetching cron jobs: #{Exception.message(e)}")
      {:error, "Exception: #{Exception.message(e)}"}
  end

  @doc """
  Fetches cron scheduler status.

  Returns `{:ok, status}` or `{:error, reason}`.
  """
  @spec fetch_cron_status() :: {:ok, map()} | {:error, String.t()}
  def fetch_cron_status do
    case CommandRunner.run("openclaw", ["cron", "status", "--json"], timeout: 10_000) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, status} -> {:ok, status}
          {:error, _} -> {:error, "Failed to parse cron status JSON"}
        end

      {:error, reason} ->
        {:error, "Failed to fetch cron status: #{inspect(reason)}"}
    end
  end

  # Private helpers

  defp parse_cron_output(output) do
    case Jason.decode(output) do
      {:ok, %{"jobs" => jobs}} when is_list(jobs) ->
        # Normalize job data structure
        normalized_jobs =
          Enum.map(jobs, fn job ->
            %{
              id: job["id"],
              name: job["name"],
              enabled: Map.get(job, "enabled", true),
              schedule: job["schedule"] || %{},
              state: %{
                lastRunAtMs: get_in(job, ["state", "lastRunAtMs"]),
                lastStatus: get_in(job, ["state", "lastStatus"]),
                lastDurationMs: get_in(job, ["state", "lastDurationMs"]),
                nextRunAtMs: get_in(job, ["state", "nextRunAtMs"]),
                consecutiveErrors: get_in(job, ["state", "consecutiveErrors"]) || 0
              }
            }
          end)

        {:ok, normalized_jobs}

      {:ok, _other} ->
        {:error, "Unexpected JSON structure from openclaw cron list"}

      {:error, decode_error} ->
        Logger.error("[CronMonitor] JSON decode error: #{inspect(decode_error)}")
        {:error, "Failed to parse cron jobs JSON"}
    end
  end
end
