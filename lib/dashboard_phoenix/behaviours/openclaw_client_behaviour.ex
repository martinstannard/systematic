defmodule DashboardPhoenix.Behaviours.OpenClawClientBehaviour do
  @moduledoc """
  Behaviour for OpenClaw client operations.
  """

  @doc "Send a work request to OpenClaw for a ticket"
  @callback work_on_ticket(String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, String.t()}

  @doc "Send a raw message to the OpenClaw main session"
  @callback send_message(String.t(), keyword()) :: {:ok, :sent} | {:error, String.t()}
end