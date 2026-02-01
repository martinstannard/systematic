defmodule DashboardPhoenixWeb.PageControllerTest do
  use DashboardPhoenixWeb.ConnCase

  test "GET /page", %{conn: conn} do
    conn = get(conn, ~p"/page")
    assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
  end
end
