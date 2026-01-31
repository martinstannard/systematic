defmodule DashboardPhoenix.FileUtils do
  @moduledoc """
  File operation utilities for safe, atomic file operations.
  
  Prevents race conditions when multiple processes write to the same files.
  """

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
    tmp_path = "#{path}.tmp.#{System.unique_integer([:positive])}"
    
    with :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, path) do
      :ok
    else
      error ->
        # Clean up temp file if it exists
        File.rm(tmp_path)
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
end