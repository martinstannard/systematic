defmodule DashboardPhoenix.CLITools do
  @moduledoc """
  Utility module for checking CLI tool availability and providing graceful fallbacks.

  This module helps monitors gracefully handle missing CLI tools by:
  - Checking if tools exist before calling them
  - Providing user-friendly error messages
  - Caching availability checks to avoid repeated filesystem calls
  """

  require Logger

  @doc """
  Check if a CLI tool is available and executable.

  Returns `{:ok, path}` if the tool exists, or `{:error, reason}` if not.
  Caches results for 5 minutes to avoid repeated filesystem checks.
  """
  def check_tool(tool_name) when is_binary(tool_name) do
    cache_key = {:cli_tool, tool_name}

    current_time = System.monotonic_time(:second)

    case :ets.lookup(:cli_tools_cache, cache_key) do
      [{^cache_key, result, expires_at}] ->
        if expires_at > current_time do
          result
        else
          result = do_check_tool(tool_name)
          # 5 minutes
          expires_at = current_time + 300
          :ets.insert(:cli_tools_cache, {cache_key, result, expires_at})
          result
        end

      _ ->
        result = do_check_tool(tool_name)
        # 5 minutes
        expires_at = current_time + 300
        :ets.insert(:cli_tools_cache, {cache_key, result, expires_at})
        result
    end
  end

  @doc """
  Check if a CLI tool is available, with a friendly name for error messages.
  """
  def check_tool(tool_name, friendly_name)
      when is_binary(tool_name) and is_binary(friendly_name) do
    case check_tool(tool_name) do
      {:ok, path} -> {:ok, path}
      {:error, reason} -> {:error, {reason, friendly_name}}
    end
  end

  @doc """
  Run a command only if the tool exists, otherwise return a graceful error.

  This is a wrapper around CommandRunner.run that first checks tool availability.
  """
  def run_if_available(command, args, opts \\ []) do
    friendly_name = Keyword.get(opts, :friendly_name, command)

    case check_tool(command, friendly_name) do
      {:ok, _path} ->
        DashboardPhoenix.CommandRunner.run(command, args, opts)

      {:error, {reason, name}} ->
        error_msg = format_missing_tool_message(name, reason)
        Logger.info("CLI tool not available: #{error_msg}")
        {:error, {:tool_not_available, error_msg}}
    end
  end

  @doc """
  Similar to run_if_available but for JSON commands.
  """
  def run_json_if_available(command, args, opts \\ []) do
    friendly_name = Keyword.get(opts, :friendly_name, command)

    case check_tool(command, friendly_name) do
      {:ok, _path} ->
        DashboardPhoenix.CommandRunner.run_json(command, args, opts)

      {:error, {reason, name}} ->
        error_msg = format_missing_tool_message(name, reason)
        Logger.info("CLI tool not available: #{error_msg}")
        {:error, {:tool_not_available, error_msg}}
    end
  end

  @doc """
  Check multiple tools at once and return a summary.
  Useful for monitor initialization to check all dependencies.
  """
  def check_tools(tools) when is_list(tools) do
    results =
      tools
      |> Enum.map(fn
        {tool, friendly_name} -> {tool, friendly_name, check_tool(tool, friendly_name)}
        tool when is_binary(tool) -> {tool, tool, check_tool(tool)}
      end)

    missing =
      results
      |> Enum.filter(fn {_tool, _name, result} -> match?({:error, _}, result) end)
      |> Enum.map(fn {_tool, name, {:error, {reason, _}}} -> {name, reason} end)

    available =
      results
      |> Enum.filter(fn {_tool, _name, result} -> match?({:ok, _}, result) end)
      |> Enum.map(fn {_tool, name, {:ok, path}} -> {name, path} end)

    %{
      available: available,
      missing: missing,
      all_available?: Enum.empty?(missing)
    }
  end

  @doc """
  Generate a user-friendly status message for tool availability.
  """
  def format_status_message(%{available: available, missing: missing}) do
    cond do
      Enum.empty?(missing) ->
        "All CLI tools available (#{length(available)} tools)"

      Enum.empty?(available) ->
        "No CLI tools available. Missing: #{format_missing_list(missing)}"

      true ->
        "Some CLI tools missing. Available: #{format_available_list(available)}. Missing: #{format_missing_list(missing)}"
    end
  end

  # Private functions

  defp do_check_tool(tool_name) do
    case System.find_executable(tool_name) do
      nil ->
        {:error, :not_found}

      path ->
        # System.find_executable already verifies the file is executable
        # Just verify the file still exists and is accessible
        case File.stat(path) do
          {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] ->
            {:ok, path}

          {:ok, %File.Stat{type: type}} ->
            {:error, {:invalid_type, type}}

          {:error, reason} ->
            {:error, {:stat_failed, reason}}
        end
    end
  end

  defp format_missing_tool_message(tool_name, reason) do
    base_message =
      case reason do
        :not_found ->
          "#{tool_name} command not found in PATH"

        :not_executable ->
          "#{tool_name} found but not executable"

        {:stat_failed, stat_reason} ->
          "#{tool_name} found but cannot check permissions: #{stat_reason}"

        other ->
          "#{tool_name} unavailable: #{other}"
      end

    base_message <> ". " <> suggest_installation(tool_name)
  end

  defp suggest_installation(tool_name) do
    case String.downcase(tool_name) do
      name when name in ["linear", "linear cli"] ->
        "Install with: npm install -g @linear/cli"

      name when name in ["gh", "github cli"] ->
        "Install from https://cli.github.com/ or your package manager"

      name when name in ["chainlink", "chainlink cli"] ->
        "Install chainlink from your project's bin directory or build it with: mix escript.build"

      name when name in ["opencode"] ->
        "Install from https://github.com/opencode-ai/opencode or your package manager"

      name when name in ["git"] ->
        "Install git from https://git-scm.com/ or your package manager"

      name when name in ["ps", "kill", "find", "sh"] ->
        "This is a core system command. Check your PATH or system installation"

      _ ->
        "Please install #{tool_name} and ensure it's in your PATH"
    end
  end

  defp format_missing_list(missing) do
    missing
    |> Enum.map(fn {name, _reason} -> name end)
    |> Enum.join(", ")
  end

  defp format_available_list(available) do
    available
    |> Enum.map(fn {name, _path} -> name end)
    |> Enum.join(", ")
  end

  # Initialize the ETS cache table if it doesn't exist
  def ensure_cache_table do
    unless :ets.info(:cli_tools_cache) != :undefined do
      :ets.new(:cli_tools_cache, [:set, :public, :named_table])
    end
  end
end
