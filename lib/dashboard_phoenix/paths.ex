defmodule DashboardPhoenix.Paths do
  @moduledoc """
  Centralized path resolution for the dashboard.
  
  All paths are configurable via environment variables or application config,
  with sensible defaults using System.user_home!/0.
  
  ## Configuration Priority
  
  1. Environment variables (highest)
  2. Application config
  3. Default based on home directory (lowest)
  
  ## Environment Variables
  
  - `OPENCLAW_HOME` - Base directory for OpenClaw data (default: $HOME/.openclaw)
  - `OPENCLAW_SESSIONS_DIR` - Sessions directory (default: $OPENCLAW_HOME/agents/main/sessions)
  - `GEMINI_BIN` - Path to Gemini CLI binary
  - `LINEAR_CLI` - Path to Linear CLI binary
  - `OPENCODE_BIN` - Path to OpenCode binary
  - `DEFAULT_WORK_DIR` - Default working directory for coding tasks
  - `CLAUDE_STATS_FILE` - Claude stats cache file (default: $HOME/.claude/stats-cache.json)
  - `AGENT_PROGRESS_FILE` - Agent progress JSONL file (default: /tmp/agent-progress.jsonl)
  """

  @doc """
  Get the OpenClaw home directory.
  Default: $HOME/.openclaw
  """
  def openclaw_home do
    System.get_env("OPENCLAW_HOME") ||
      Application.get_env(:dashboard_phoenix, :openclaw_home) ||
      Path.join(System.user_home!(), ".openclaw")
  end

  @doc """
  Get the OpenClaw sessions directory.
  Default: $OPENCLAW_HOME/agents/main/sessions
  """
  def openclaw_sessions_dir do
    System.get_env("OPENCLAW_SESSIONS_DIR") ||
      Application.get_env(:dashboard_phoenix, :openclaw_sessions_dir) ||
      Path.join([openclaw_home(), "agents", "main", "sessions"])
  end

  @doc """
  Get the sessions.json file path.
  """
  def sessions_file do
    Application.get_env(:dashboard_phoenix, :sessions_file) ||
      Path.join(openclaw_sessions_dir(), "sessions.json")
  end

  @doc """
  Get the PR verification file path.
  Default: $OPENCLAW_HOME/pr-verified.json
  """
  def pr_verification_file do
    System.get_env("PR_VERIFICATION_FILE") ||
      Application.get_env(:dashboard_phoenix, :pr_verification_file) ||
      Path.join(openclaw_home(), "pr-verified.json")
  end

  @doc """
  Get the PR state file path (for systematic dashboard).
  Default: $OPENCLAW_HOME/systematic-pr-state.json
  """
  def pr_state_file do
    System.get_env("PR_STATE_FILE") ||
      Application.get_env(:dashboard_phoenix, :pr_state_file) ||
      Path.join(openclaw_home(), "systematic-pr-state.json")
  end

  @doc """
  Get the Gemini CLI binary path.
  Default: gemini (searches PATH)
  """
  def gemini_bin do
    System.get_env("GEMINI_BIN") ||
      Application.get_env(:dashboard_phoenix, :gemini_bin) ||
      find_in_path("gemini") ||
      Path.join([System.user_home!(), ".npm-global", "bin", "gemini"])
  end

  @doc """
  Get the Linear CLI binary path.
  Default: linear (searches PATH)
  """
  def linear_cli do
    System.get_env("LINEAR_CLI") ||
      Application.get_env(:dashboard_phoenix, :linear_cli) ||
      find_in_path("linear") ||
      Path.join([System.user_home!(), ".npm-global", "bin", "linear"])
  end

  @doc """
  Get the OpenCode binary path.
  Default: /usr/bin/opencode
  """
  def opencode_bin do
    System.get_env("OPENCODE_BIN") ||
      Application.get_env(:dashboard_phoenix, :opencode_bin) ||
      find_in_path("opencode") ||
      "/usr/bin/opencode"
  end

  @doc """
  Get the Chainlink CLI binary path.
  Default: chainlink (searches PATH)
  """
  def chainlink_bin do
    System.get_env("CHAINLINK_BIN") ||
      Application.get_env(:dashboard_phoenix, :chainlink_bin) ||
      find_in_path("chainlink") ||
      Path.join([System.user_home!(), "bin", "chainlink"])
  end

  @doc """
  Get the default working directory for coding tasks.
  Default: $HOME/work/core-platform
  """
  def default_work_dir do
    System.get_env("DEFAULT_WORK_DIR") ||
      Application.get_env(:dashboard_phoenix, :default_work_dir) ||
      Path.join([System.user_home!(), "work", "core-platform"])
  end

  @doc """
  Get the clawd workspace directory.
  Default: $HOME/clawd
  """
  def clawd_dir do
    System.get_env("CLAWD_DIR") ||
      Application.get_env(:dashboard_phoenix, :clawd_dir) ||
      Path.join(System.user_home!(), "clawd")
  end

  @doc """
  Get the systematic repository path.
  Default: $HOME/code/systematic
  """
  def systematic_repo do
    System.get_env("SYSTEMATIC_REPO_PATH") ||
      Application.get_env(:dashboard_phoenix, :systematic_repo_path) ||
      Path.join([System.user_home!(), "code", "systematic"])
  end

  @doc """
  Get the core platform repository path.
  Default: $HOME/code/core-platform
  """
  def core_platform_repo do
    System.get_env("CORE_PLATFORM_REPO") ||
      Application.get_env(:dashboard_phoenix, :core_platform_repo) ||
      Path.join([System.user_home!(), "code", "core-platform"])
  end

  @doc """
  Get the dashboard phoenix directory.
  Default: $CLAWD_DIR/dashboard_phoenix (but we should use Application.app_dir in prod)
  """
  def dashboard_phoenix_dir do
    # In releases, use the app directory
    if Application.get_env(:dashboard_phoenix, :use_app_dir, false) do
      Application.app_dir(:dashboard_phoenix)
    else
      Application.get_env(:dashboard_phoenix, :dashboard_phoenix_dir) ||
        Path.join(clawd_dir(), "dashboard_phoenix")
    end
  end

  @doc """
  Get the Claude stats cache file path.
  Default: $HOME/.claude/stats-cache.json
  """
  def claude_stats_file do
    System.get_env("CLAUDE_STATS_FILE") ||
      Application.get_env(:dashboard_phoenix, :claude_stats_file) ||
      Path.join([System.user_home!(), ".claude", "stats-cache.json"])
  end

  @doc """
  Get the agent progress file path.
  Default: /tmp/agent-progress.jsonl
  """
  def progress_file do
    System.get_env("AGENT_PROGRESS_FILE") ||
      Application.get_env(:dashboard_phoenix, :progress_file) ||
      "/tmp/agent-progress.jsonl"
  end

  @doc """
  Get the agent preferences file path.
  Default: $OPENCLAW_HOME/dashboard-prefs.json
  """
  def preferences_file do
    System.get_env("DASHBOARD_PREFS_FILE") ||
      Application.get_env(:dashboard_phoenix, :preferences_file) ||
      Path.join(openclaw_home(), "dashboard-prefs.json")
  end

  # Private helpers

  defp find_in_path(binary) do
    case System.find_executable(binary) do
      nil -> nil
      path -> path
    end
  end
end
