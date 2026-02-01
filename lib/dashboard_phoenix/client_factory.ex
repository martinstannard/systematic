defmodule DashboardPhoenix.ClientFactory do
  @moduledoc """
  Factory module to return appropriate client implementations based on environment.

  In test environment, returns mock implementations that can be configured with Mox.
  In other environments (dev, prod), returns real client implementations.

  This pattern enables:
  - Easy dependency injection for testing
  - Consistent interface across environments
  - Swappable implementations without code changes

  ## Usage

      # In your module
      alias DashboardPhoenix.ClientFactory

      def call_opencode do
        client = ClientFactory.opencode_client()
        client.some_function()
      end

      # In tests (with Mox)
      import Mox
      expect(DashboardPhoenix.Mocks.OpenCodeClientMock, :some_function, fn -> :ok end)

  """

  @doc """
  Returns the OpenCode client module for the current environment.

  ## Returns

  - A mock module in test environment (for Mox testing)
  - `DashboardPhoenix.OpenCodeClient` in dev/prod environments

  ## Examples

      iex> DashboardPhoenix.ClientFactory.opencode_client()
      DashboardPhoenix.OpenCodeClient  # in dev/prod

  """
  @spec opencode_client() :: module()
  def opencode_client do
    case Mix.env() do
      :test -> DashboardPhoenix.Mocks.OpenCodeClientMock
      _ -> DashboardPhoenix.OpenCodeClient
    end
  end

  @doc """
  Returns the OpenClaw client module for the current environment.

  ## Returns

  - A mock module in test environment (for Mox testing)
  - `DashboardPhoenix.OpenClawClient` in dev/prod environments

  ## Examples

      iex> DashboardPhoenix.ClientFactory.openclaw_client()
      DashboardPhoenix.OpenClawClient  # in dev/prod

  """
  @spec openclaw_client() :: module()
  def openclaw_client do
    case Mix.env() do
      :test -> DashboardPhoenix.Mocks.OpenClawClientMock
      _ -> DashboardPhoenix.OpenClawClient
    end
  end
end