defmodule DashboardPhoenix.FileSystem do
  @moduledoc """
  Wrapper for file system operations that can be mocked in tests.
  """

  @behaviour DashboardPhoenix.Behaviours.FileSystemBehaviour

  @impl true
  def read(path), do: File.read(path)

  @impl true
  def write(path, content), do: File.write(path, content)

  @impl true
  def write!(path, content), do: File.write!(path, content)

  @impl true
  def rm(path), do: File.rm(path)

  @impl true
  def exists?(path), do: File.exists?(path)

  @impl true
  def atomic_write(path, content) do
    DashboardPhoenix.FileUtils.atomic_write(path, content)
  end

  @doc """
  Get the configured file system implementation.
  In production/dev: real File module
  In tests: mock implementation
  """
  def implementation do
    Application.get_env(:dashboard_phoenix, :file_system, __MODULE__)
  end
end
