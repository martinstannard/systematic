defmodule DashboardPhoenix.Behaviours.FileSystemBehaviour do
  @moduledoc """
  Behaviour for file system operations to enable proper mocking in tests.
  """

  @doc "Read file contents"
  @callback read(String.t()) :: {:ok, binary()} | {:error, atom()}

  @doc "Write content to a file"
  @callback write(String.t(), iodata()) :: :ok | {:error, atom()}

  @doc "Write content to a file, raising on error"
  @callback write!(String.t(), iodata()) :: :ok

  @doc "Remove/delete a file"
  @callback rm(String.t()) :: :ok | {:error, atom()}

  @doc "Check if file exists"
  @callback exists?(String.t()) :: boolean()

  @doc "Atomic write operation"
  @callback atomic_write(String.t(), iodata()) :: :ok | {:error, atom()}
end