defmodule DashboardPhoenix.AgentTypes do
  @moduledoc """
  Centralized agent type constants for consistent agent handling across the dashboard.

  Use these module attributes instead of magic atoms/strings to prevent typos
  and ease refactoring.

  ## Usage

      alias DashboardPhoenix.AgentTypes

      # Direct use
      agent_type = AgentTypes.opencode()

      # Check if agent type is valid
      if agent_type in AgentTypes.all_types(), do: ...

      # Pattern matching with guards
      import DashboardPhoenix.AgentTypes, only: [is_valid_agent_type: 1]
      def handle_agent(type) when is_valid_agent_type(type), do: ...
  """

  # Agent type atoms
  @opencode :opencode
  @claude :claude
  @gemini :gemini
  @subagent :subagent
  @claude_code :claude_code

  # Agent type accessors
  @doc "Returns the OpenCode agent type atom"
  @spec opencode() :: :opencode
  def opencode, do: @opencode

  @doc "Returns the Claude agent type atom"
  @spec claude() :: :claude
  def claude, do: @claude

  @doc "Returns the Gemini agent type atom"
  @spec gemini() :: :gemini
  def gemini, do: @gemini

  @doc "Returns the subagent type atom"
  @spec subagent() :: :subagent
  def subagent, do: @subagent

  @doc "Returns the Claude Code agent type atom"
  @spec claude_code() :: :claude_code
  def claude_code, do: @claude_code

  # Agent string names (for persistence/UI)
  @doc "Returns the OpenCode agent name as string"
  @spec opencode_str() :: String.t()
  def opencode_str, do: "opencode"

  @doc "Returns the Claude agent name as string"
  @spec claude_str() :: String.t()
  def claude_str, do: "claude"

  @doc "Returns the Gemini agent name as string"
  @spec gemini_str() :: String.t()
  def gemini_str, do: "gemini"

  # Agent type lists
  @doc "Returns all primary coding agent types"
  @spec coding_agents() :: [:opencode | :claude | :gemini]
  def coding_agents, do: [@opencode, @claude, @gemini]

  @doc "Returns all agent types including subagent"
  @spec all_types() :: [:opencode | :claude | :gemini | :subagent | :claude_code]
  def all_types, do: [@opencode, @claude, @gemini, @subagent, @claude_code]

  @doc "Returns valid agent name strings"
  @spec valid_agent_strings() :: [String.t()]
  def valid_agent_strings, do: ["opencode", "claude", "gemini"]

  # Conversion
  @doc "Converts agent string to atom"
  @spec to_atom(String.t() | atom()) :: atom()
  def to_atom("opencode"), do: @opencode
  def to_atom("claude"), do: @claude
  def to_atom("gemini"), do: @gemini
  def to_atom(atom) when is_atom(atom), do: atom

  @doc "Converts agent atom to string"
  @spec to_string(atom()) :: String.t()
  def to_string(@opencode), do: "opencode"
  def to_string(@claude), do: "claude"
  def to_string(@gemini), do: "gemini"
  def to_string(other), do: Atom.to_string(other)

  # Validation
  @doc "Checks if an atom is a valid coding agent type"
  @spec valid_coding_agent?(atom()) :: boolean()
  def valid_coding_agent?(type), do: type in coding_agents()

  @doc "Checks if a string is a valid agent name"
  @spec valid_agent_string?(String.t()) :: boolean()
  def valid_agent_string?(name), do: name in valid_agent_strings()

  # Guards
  defguard is_valid_agent_type(type) when type in [:opencode, :claude, :gemini, :subagent, :claude_code]
  defguard is_coding_agent(type) when type in [:opencode, :claude, :gemini]
end
