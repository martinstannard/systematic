defmodule DashboardPhoenix.Behaviours.OpenCodeClientBehaviour do
  @moduledoc """
  Behaviour for OpenCode client operations.
  """

  @doc "Send a task/prompt to OpenCode"
  @callback send_task(String.t(), keyword()) :: {:ok, map()} | {:error, String.t()}

  @doc "Check OpenCode server health"
  @callback health_check() :: :ok | {:error, term()}

  @doc "List all sessions from OpenCode server"
  @callback list_sessions() :: {:ok, list()} | {:error, term()}

  @doc "List sessions formatted for dashboard display"
  @callback list_sessions_formatted() :: {:ok, list()} | {:error, term()}

  @doc "Send a message to an existing session"
  @callback send_message(String.t(), String.t()) :: {:ok, :sent} | {:error, String.t()}

  @doc "Delete/close a session by ID"
  @callback delete_session(String.t()) :: :ok | {:error, String.t()}
end