defmodule DashboardPhoenix.Models do
  @moduledoc """
  Centralized model name constants for consistent model handling across the dashboard.

  Use these module attributes instead of magic strings to prevent typos
  and ease refactoring.

  ## Usage

      alias DashboardPhoenix.Models

      # Direct use
      model = Models.claude_opus()

      # Check if model is valid
      if model in Models.claude_models(), do: ...
  """

  # Claude models
  @claude_opus "anthropic/claude-opus-4-5"
  @claude_sonnet "anthropic/claude-sonnet-4-20250514"

  # Gemini models
  @gemini_3_pro "gemini-3-pro"
  @gemini_3_flash "gemini-3-flash"
  @gemini_2_5_pro "gemini-2.5-pro"
  @gemini_2_flash "gemini-2.0-flash"

  # Model accessors - Claude
  @doc "Returns the Claude Opus model identifier"
  @spec claude_opus() :: String.t()
  def claude_opus, do: @claude_opus

  @doc "Returns the Claude Sonnet model identifier"
  @spec claude_sonnet() :: String.t()
  def claude_sonnet, do: @claude_sonnet

  # Model accessors - Gemini
  @doc "Returns the Gemini 3 Pro model identifier"
  @spec gemini_3_pro() :: String.t()
  def gemini_3_pro, do: @gemini_3_pro

  @doc "Returns the Gemini 3 Flash model identifier"
  @spec gemini_3_flash() :: String.t()
  def gemini_3_flash, do: @gemini_3_flash

  @doc "Returns the Gemini 2.5 Pro model identifier"
  @spec gemini_2_5_pro() :: String.t()
  def gemini_2_5_pro, do: @gemini_2_5_pro

  @doc "Returns the Gemini 2.0 Flash model identifier"
  @spec gemini_2_flash() :: String.t()
  def gemini_2_flash, do: @gemini_2_flash

  # Model lists
  @doc "Returns all available Claude models"
  @spec claude_models() :: [String.t()]
  def claude_models, do: [@claude_opus, @claude_sonnet]

  @doc "Returns all available Gemini models"
  @spec gemini_models() :: [String.t()]
  def gemini_models, do: [@gemini_3_pro, @gemini_3_flash, @gemini_2_5_pro, @gemini_2_flash]

  @doc "Returns all available models"
  @spec all_models() :: [String.t()]
  def all_models, do: claude_models() ++ gemini_models()

  # Defaults
  @doc "Returns the default Claude model"
  @spec default_claude_model() :: String.t()
  def default_claude_model, do: @claude_opus

  @doc "Returns the default OpenCode/Gemini model"
  @spec default_opencode_model() :: String.t()
  def default_opencode_model, do: @gemini_3_pro

  # Validation
  @doc "Checks if a model string is a valid Claude model"
  @spec valid_claude_model?(String.t()) :: boolean()
  def valid_claude_model?(model), do: model in claude_models()

  @doc "Checks if a model string is a valid Gemini model"
  @spec valid_gemini_model?(String.t()) :: boolean()
  def valid_gemini_model?(model), do: model in gemini_models()

  @doc "Checks if a model string is valid"
  @spec valid_model?(String.t()) :: boolean()
  def valid_model?(model), do: model in all_models()
end
