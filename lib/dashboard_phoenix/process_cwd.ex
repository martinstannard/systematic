defmodule DashboardPhoenix.ProcessCwd do
  @moduledoc """
  Cross-platform utility for retrieving a process's current working directory.

  Supports:
  - **Linux**: Uses `/proc/<pid>/cwd` symlink (fast, no external command)
  - **macOS**: Uses `lsof -a -p <pid> -d cwd -Fn` (requires lsof)
  - **Fallback**: Returns `nil` on unsupported platforms

  ## Examples

      iex> DashboardPhoenix.ProcessCwd.get(12345)
      {:ok, "/home/user/project"}

      iex> DashboardPhoenix.ProcessCwd.get(99999)
      {:error, :not_found}

      iex> DashboardPhoenix.ProcessCwd.get!(12345)
      "/home/user/project"

      iex> DashboardPhoenix.ProcessCwd.get!(99999)
      nil

  """

  require Logger

  @doc """
  Gets the current working directory for a process.

  ## Parameters
  - `pid` - Process ID (integer or string)

  ## Returns
  - `{:ok, path}` - Successfully retrieved the cwd
  - `{:error, :not_found}` - Process doesn't exist or cwd can't be read
  - `{:error, :unsupported}` - Platform not supported
  """
  @spec get(integer() | binary()) :: {:ok, String.t()} | {:error, :not_found | :unsupported}
  def get(pid) when is_binary(pid) do
    case Integer.parse(pid) do
      {int_pid, ""} -> get(int_pid)
      _ -> {:error, :not_found}
    end
  end

  def get(pid) when is_integer(pid) do
    case :os.type() do
      {:unix, :linux} -> get_cwd_linux(pid)
      {:unix, :darwin} -> get_cwd_macos(pid)
      {:unix, _} -> get_cwd_unix_fallback(pid)
      _ -> {:error, :unsupported}
    end
  end

  @doc """
  Gets the current working directory, returning `nil` on any error.

  This is a convenience function for when you don't care about the error reason.
  """
  @spec get!(integer() | binary()) :: String.t() | nil
  def get!(pid) do
    case get(pid) do
      {:ok, path} -> path
      {:error, _} -> nil
    end
  end

  # Linux: Read the /proc/<pid>/cwd symlink directly
  defp get_cwd_linux(pid) do
    proc_path = "/proc/#{pid}/cwd"
    case File.read_link(proc_path) do
      {:ok, cwd} -> {:ok, cwd}
      {:error, _} -> {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # macOS: Use lsof to find the cwd
  # lsof -a -p PID -d cwd -Fn outputs:
  # p<pid>
  # n<cwd>
  defp get_cwd_macos(pid) do
    case System.cmd("lsof", ["-a", "-p", to_string(pid), "-d", "cwd", "-Fn"], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse the lsof output - look for line starting with 'n'
        case parse_lsof_output(output) do
          nil -> {:error, :not_found}
          path -> {:ok, path}
        end

      {_, _} ->
        {:error, :not_found}
    end
  rescue
    e ->
      Logger.debug("Failed to get cwd via lsof: #{inspect(e)}")
      {:error, :not_found}
  end

  # Generic Unix fallback - try pwdx if available, then lsof
  defp get_cwd_unix_fallback(pid) do
    with {:error, _} <- try_pwdx(pid),
         {:error, _} <- get_cwd_macos(pid) do
      {:error, :not_found}
    end
  end

  # Try pwdx (available on some Unix systems)
  defp try_pwdx(pid) do
    case System.cmd("pwdx", [to_string(pid)], stderr_to_stdout: true) do
      {output, 0} ->
        # pwdx outputs: "PID: /path/to/cwd"
        case String.split(output, ": ", parts: 2) do
          [_, path] -> {:ok, String.trim(path)}
          _ -> {:error, :not_found}
        end

      {_, _} ->
        {:error, :not_found}
    end
  rescue
    _ -> {:error, :not_found}
  end

  # Parse lsof -Fn output to extract the cwd path
  defp parse_lsof_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case line do
        "n" <> path when path != "" -> String.trim(path)
        _ -> nil
      end
    end)
  end
end
