# Stub modules to prevent compilation warnings
# These are overridden by test/support/mocks.ex in test environment

defmodule DashboardPhoenix.Mocks.OpenCodeClientMock do
  @moduledoc false
  def list_sessions_formatted, do: {:ok, []}
  def send_message(_id, _msg), do: {:ok, "stub"}
  def send_task(_prompt, _opts \\ []), do: {:ok, "stub"}
  def delete_session(_id), do: :ok
end

defmodule DashboardPhoenix.Mocks.OpenClawClientMock do
  @moduledoc false
  def send_message(_msg, _opts \\ []), do: {:ok, "stub"}
  def spawn_subagent(_prompt, _opts \\ []), do: {:ok, "stub"}
  def work_on_ticket(_id, _details, _opts \\ []), do: {:ok, "stub"}
end
