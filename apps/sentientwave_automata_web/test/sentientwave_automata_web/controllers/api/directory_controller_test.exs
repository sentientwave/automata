defmodule SentientwaveAutomataWeb.API.DirectoryControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  import Plug.Test, only: [init_test_session: 2]

  test "requires admin auth", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/directory/users")
    assert json_response(conn, 401)["error"] == "admin_auth_required"
  end

  test "upserts and lists users for authenticated admin", %{conn: conn} do
    conn = init_test_session(conn, automata_admin_authenticated: true)

    conn =
      post(conn, ~p"/api/v1/directory/users", %{
        "localpart" => "qauser",
        "kind" => "person",
        "display_name" => "QA User",
        "password" => "qauser-pass-01"
      })

    assert json_response(conn, 200)["data"]["localpart"] == "qauser"

    conn =
      get(
        init_test_session(build_conn(), automata_admin_authenticated: true),
        ~p"/api/v1/directory/users"
      )

    assert Enum.any?(json_response(conn, 200)["data"], &(&1["localpart"] == "qauser"))
  end
end
