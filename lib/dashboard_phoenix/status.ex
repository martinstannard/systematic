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
  @pending "pending"

  # Error statuses
  @error "error"
  @failed "failed"
  @crashed "crashed"
  @failure "failure"

  # Process statuses
  @zombie "zombie"
  @dead "dead"

  # CI/Pipeline statuses
  @success "success"

  # Linear workflow statuses
  @triage "Triage"
  @backlog "Backlog"
  @todo "Todo"
  @in_review "In Review"
  @in_progress "In Progress"

  # Status accessors - Agent/Session
  def running, do: @running
  def idle, do: @idle
  def active, do: @active
  def busy, do: @busy
  def completed, do: @completed
  def done, do: @done
  def stopped, do: @stopped
  def spawned, do: @spawned
  def pending, do: @pending

  # Status accessors - Error
  def error, do: @error
  def failed, do: @failed
  def crashed, do: @crashed
  def failure, do: @failure

  # Status accessors - Process
  def zombie, do: @zombie
  def dead, do: @dead

  # Status accessors - CI/Pipeline
  def success, do: @success

  # Status accessors - Linear workflow
  def triage, do: @triage
  def backlog, do: @backlog
  def todo, do: @todo
  def in_review, do: @in_review
  def in_progress, do: @in_progress

  @doc """
  Returns a list of Linear workflow states.
  """
  def linear_states, do: [@triage, @backlog, @todo, @in_review]

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
  def error_statuses, do: [@error, @failed, @crashed, @failure]

  @doc """
  Returns a list of statuses that indicate the process is no longer active.
  """
  def inactive_statuses, do: [@stopped, @zombie, @dead]

  @doc """
  Returns a list of statuses that indicate completion (successful or failed).
  """
  def terminal_statuses, do: [@completed, @done, @error, @failed, @crashed, @stopped]

  @doc """
  Returns a list of Linear statuses that indicate active work.
  """
  def linear_active_statuses, do: [@todo, @in_progress, @in_review]

  # Guards for pattern matching
  defguard is_active_status(status) when status in [@running, @active, @busy]

  defguard is_in_progress_status(status)
           when status in [@running, @idle, @active, @busy, @spawned]

  defguard is_error_status(status) when status in [@error, @failed, @crashed, @failure]
  defguard is_inactive_status(status) when status in [@stopped, @zombie, @dead]
  defguard is_linear_status(status) when status in [@triage, @backlog, @todo, @in_review]
end
