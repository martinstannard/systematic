defmodule DashboardPhoenix.Behaviours.SessionBridgeBehaviour do
  @moduledoc """
  Behaviour for session bridge operations to enable proper mocking in tests.
  """

  @doc "Get agent sessions"
  @callback get_sessions() :: list()

  @doc "Get progress events"
  @callback get_progress() :: list()

  @doc "Subscribe to session updates"
  @callback subscribe() :: :ok

  @doc "Clear all progress"
  @callback clear_progress() :: :ok
end
