defmodule DashboardPhoenix.Status do
  @moduledoc """
  Centralized status constants for consistent status handling across the dashboard.

  Use these module attributes instead of magic strings to prevent typos
  and ease refactoring.

  ## Usage

      alias DashboardPhoenix.Status

      # Direct use
      status = Status.running()

      # Pattern matching (use the macros)
      import DashboardPhoenix.Status, only: [is_active_status: 1, is_error_status: 1]

      if is_active_status(status), do: ...

      # Or use the list functions for `in` checks
      if status in Status.active_statuses(), do: ...
  """

  # Primary agent/session statuses
  @running "running"
  @idle "idle"
  @active "active"
  @busy "busy"
  @completed "completed"
  @done "done"
  @stopped "stopped"
  @spawned "spawned"

  # Error statuses
  @error "error"
  @failed "failed"
  @crashed "crashed"

  # Process statuses
  @zombie "zombie"
  @dead "dead"

  # Status accessors
  def running, do: @running
  def idle, do: @idle
  def active, do: @active
  def busy, do: @busy
  def completed, do: @completed
  def done, do: @done
  def stopped, do: @stopped
  def spawned, do: @spawned
  def error, do: @error
  def failed, do: @failed
  def crashed, do: @crashed
  def zombie, do: @zombie
  def dead, do: @dead

  @doc """
  Returns a list of statuses that indicate the agent/process is actively working.
  """
  def active_statuses, do: [@running, @active, @busy]

  @doc """
  Returns a list of statuses that indicate the agent/session is in progress (not completed).
  """
  def in_progress_statuses, do: [@running, @idle, @active, @busy, @spawned]

  @doc """
  Returns a list of statuses that indicate an error condition.
  """
  def error_statuses, do: [@error, @failed, @crashed]

  @doc """
  Returns a list of statuses that indicate the process is no longer active.
  """
  def inactive_statuses, do: [@stopped, @zombie, @dead]

  @doc """
  Returns a list of statuses that indicate completion (successful or failed).
  """
  def terminal_statuses, do: [@completed, @done, @error, @failed, @crashed, @stopped]

  # Guards for pattern matching
  defguard is_active_status(status) when status in [@running, @active, @busy]
  defguard is_in_progress_status(status) when status in [@running, @idle, @active, @busy, @spawned]
  defguard is_error_status(status) when status in [@error, @failed, @crashed]
  defguard is_inactive_status(status) when status in [@stopped, @zombie, @dead]
end
