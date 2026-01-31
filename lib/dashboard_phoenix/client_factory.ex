defmodule DashboardPhoenix.ClientFactory do
  @moduledoc """
  Factory module to return appropriate client implementations based on environment.
  In test environment, returns mock implementations. In other environments, returns real clients.
  """

  def opencode_client do
    case Mix.env() do
      :test -> DashboardPhoenix.Mocks.OpenCodeClientMock
      _ -> DashboardPhoenix.OpenCodeClient
    end
  end

  def openclaw_client do
    case Mix.env() do
      :test -> DashboardPhoenix.Mocks.OpenClawClientMock
      _ -> DashboardPhoenix.OpenClawClient
    end
  end
end