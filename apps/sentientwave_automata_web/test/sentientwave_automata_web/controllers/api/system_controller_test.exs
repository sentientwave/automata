defmodule SentientwaveAutomataWeb.API.SystemControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  import Plug.Test, only: [init_test_session: 2]

  test "GET /api/v1/system/status returns unauthorized when not authenticated", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/system/status")
    body = json_response(conn, 401)

    assert body["error"] == "admin_auth_required"
  end

  test "GET /api/v1/system/status returns system data for authenticated admin", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/api/v1/system/status")

    body = json_response(conn, 200)

    assert is_map(body["data"])
    assert body["data"]["company_name"] != nil
    assert is_map(body["data"]["services"])
  end
end
