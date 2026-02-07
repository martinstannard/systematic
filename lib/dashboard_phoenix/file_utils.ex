defmodule DashboardPhoenix.FileUtils do
  @moduledoc """
  File operation utilities for safe, atomic file operations.

  Prevents race conditions when multiple processes write to the same files.

  ## Race Condition Prevention

  This module solves file operation race conditions that can occur when:
  - Multiple GenServers write to shared files (e.g., progress files, verification data)
  - Concurrent processes update JSON configuration files
  - Monitors and agents simultaneously modify state files

  Common issues prevented:
  - Partial reads (reader sees half-written content during write)
  - Corrupted data (two writers interleave their writes)
  - Lost updates (write-write race condition)
  - File truncation during concurrent access

  ## How Atomic Writes Work

  Atomic writes solve this by:
  1. Writing content to a temporary file in the same directory
  2. Using `File.rename/2` which is atomic on POSIX systems
  3. Readers either see the old complete content OR the new complete content
  4. Never see partial/corrupted data during the write operation

  This is much simpler and more reliable than file locking mechanisms.

  ## Usage in GenServers

  All modules writing to shared files should use these atomic operations:

  Instead of:
      File.write(path, content)

  Use:
      FileUtils.atomic_write(path, content)

  For JSON data (common pattern):
      FileUtils.atomic_write_json(path, data)

  ## Current Usage

  These modules already use atomic operations:
  - `SessionBridge` - for ensuring progress file integrity
  - `PRVerification` - for verified PR data
  - `AgentPreferences` - for user preference storage
  - `HomeLive` - for PR state tracking

  All new file operations should use this module to maintain consistency.
  """

  require Logger

  @doc """
  Atomically write content to a file.

  This prevents race conditions by:
  1. Writing content to a temporary file
  2. Atomically renaming the temp file to the target path

  This ensures that readers never see partially written data,
  and concurrent writes don't corrupt each other.

  ## Examples

      FileUtils.atomic_write("/path/to/file.json", json_content)
      
  ## Parameters

  - path: The target file path to write to
  - content: The content to write (binary data)
  """
  def atomic_write(path, content) do
    # Ensure parent directory exists
    dir = Path.dirname(path)
    File.mkdir_p(dir)

    # Use unique integer + pid to ensure no collisions even with concurrent processes
    tmp_path =
      "#{path}.tmp.#{System.unique_integer([:positive])}.#{:erlang.pid_to_list(self()) |> List.to_string() |> String.replace(~r/[<>]/, "")}"

    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      {:error, reason} = error ->
        # Clean up temp file if it exists
        File.rm(tmp_path)
        Logger.warning("[FileUtils] atomic_write failed for #{path}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Atomically write content to a file, raising on error.

  Same as `atomic_write/2` but raises on error instead of returning error tuples.
  """
  def atomic_write!(path, content) do
    case atomic_write(path, content) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write", path: path
    end
  end

  @doc """
  Atomically write JSON data to a file.

  Encodes the data as JSON (with pretty printing) and writes atomically.

  ## Examples

      FileUtils.atomic_write_json("/path/to/data.json", %{foo: "bar"})
      
  ## Parameters

  - path: The target file path to write to
  - data: The data to encode as JSON
  - opts: Options passed to Jason.encode/2 (default: [pretty: true])
  """
  def atomic_write_json(path, data, opts \\ [pretty: true]) do
    case Jason.encode(data, opts) do
      {:ok, json} -> atomic_write(path, json)
      {:error, reason} -> {:error, {:json_encode, reason}}
    end
  end

  @doc """
  Atomically write JSON data to a file, raising on error.
  """
  def atomic_write_json!(path, data, opts \\ [pretty: true]) do
    json = Jason.encode!(data, opts)
    atomic_write!(path, json)
  end

  @doc """
  Safely read and parse a JSON file.

  Returns `{:ok, data}` on success, `{:error, reason}` on failure.
  Handles missing files gracefully.

  ## Options

  - `:default` - Value to return if file doesn't exist (default: returns error)
  """
  def read_json(path, opts \\ []) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, :enoent} ->
        if Keyword.has_key?(opts, :default) do
          {:ok, Keyword.get(opts, :default)}
        else
          {:error, :enoent}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Atomically update a JSON file using a transformation function.

  Reads the current content, applies the function, and writes back atomically.
  This is NOT truly atomic (there's a window between read and write where
  another process could write), but it's safer than raw read-modify-write.

  For true atomicity, use a dedicated GenServer to serialize access.

  ## Examples

      # Increment a counter
      FileUtils.update_json("/path/to/counter.json", fn data ->
        Map.update(data, "count", 1, &(&1 + 1))
      end)
      
  ## Parameters

  - path: The file path
  - default: Default value if file doesn't exist
  - fun: Function that transforms the data
  """
  def update_json(path, default, fun) when is_function(fun, 1) do
    case read_json(path, default: default) do
      {:ok, data} ->
        new_data = fun.(data)
        atomic_write_json(path, new_data)

      error ->
        error
    end
  end

  @doc """
  Ensure a file exists, creating it with empty content if needed.

  Uses atomic write to create the file safely.
  """
  def ensure_exists(path, default_content \\ "") do
    if File.exists?(path) do
      :ok
    else
      atomic_write(path, default_content)
    end
  end
end
