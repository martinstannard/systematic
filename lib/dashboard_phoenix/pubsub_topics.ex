defmodule DashboardPhoenix.PubSub.Topics do
  @moduledoc """
  Centralized PubSub topic constants for the dashboard.

  All PubSub topic names should be defined here as module attributes
  to avoid magic strings scattered throughout the codebase.

  ## Usage

      alias DashboardPhoenix.PubSub.Topics

      Phoenix.PubSub.subscribe(DashboardPhoenix.PubSub, Topics.agent_activity())
      Phoenix.PubSub.broadcast(DashboardPhoenix.PubSub, Topics.agent_updates(), msg)
  """

  # Agent-related topics
  @agent_activity "agent_activity"
  @agent_updates "agent_updates"
  @agent_preferences "agent_preferences"

  # Monitor topics
  @health_check "health_check"
  @stats "stats"
  @resource_updates "resource_updates"
  @git_monitor "git_monitor"
  @branch_updates "branch_updates"
  @pr_updates "pr_updates"
  @pr_verification "pr_verification"
  @linear_updates "linear_updates"
  @chainlink_updates "chainlink_updates"

  # Server/service topics
  @activity_log "activity_log:events"
  @dashboard_state "dashboard_state"
  @deploy_manager "deploy_manager:events"
  @gemini_server "gemini_server"
  @opencode_server "opencode_server"

  # Public API - Agent topics
  @doc "Topic for agent activity broadcasts"
  @spec agent_activity() :: String.t()
  def agent_activity, do: @agent_activity

  @doc "Topic for agent updates (sessions, progress)"
  @spec agent_updates() :: String.t()
  def agent_updates, do: @agent_updates

  @doc "Topic for agent preferences changes"
  @spec agent_preferences() :: String.t()
  def agent_preferences, do: @agent_preferences

  # Public API - Monitor topics
  @doc "Topic for health check updates"
  @spec health_check() :: String.t()
  def health_check, do: @health_check

  @doc "Topic for stats monitor updates"
  @spec stats() :: String.t()
  def stats, do: @stats

  @doc "Topic for resource tracker updates"
  @spec resource_updates() :: String.t()
  def resource_updates, do: @resource_updates

  @doc "Topic for git monitor updates"
  @spec git_monitor() :: String.t()
  def git_monitor, do: @git_monitor

  @doc "Topic for branch monitor updates"
  @spec branch_updates() :: String.t()
  def branch_updates, do: @branch_updates

  @doc "Topic for PR monitor updates"
  @spec pr_updates() :: String.t()
  def pr_updates, do: @pr_updates

  @doc "Topic for PR verification updates"
  @spec pr_verification() :: String.t()
  def pr_verification, do: @pr_verification

  @doc "Topic for Linear issue updates"
  @spec linear_updates() :: String.t()
  def linear_updates, do: @linear_updates

  @doc "Topic for Chainlink ticket updates"
  @spec chainlink_updates() :: String.t()
  def chainlink_updates, do: @chainlink_updates

  # Public API - Server/service topics
  @doc "Topic for activity log events"
  @spec activity_log() :: String.t()
  def activity_log, do: @activity_log

  @doc "Topic for dashboard state updates"
  @spec dashboard_state() :: String.t()
  def dashboard_state, do: @dashboard_state

  @doc "Topic for deploy manager events"
  @spec deploy_manager() :: String.t()
  def deploy_manager, do: @deploy_manager

  @doc "Topic for Gemini server updates"
  @spec gemini_server() :: String.t()
  def gemini_server, do: @gemini_server

  @doc "Topic for OpenCode server updates"
  @spec opencode_server() :: String.t()
  def opencode_server, do: @opencode_server
end
