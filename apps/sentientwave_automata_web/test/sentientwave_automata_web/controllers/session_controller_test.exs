defmodule SentientwaveAutomataWeb.SessionControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  test "GET /login renders login form", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Admin Login"
  end

  test "POST /login authenticates with configured env credentials", %{conn: conn} do
    System.put_env("AUTOMATA_WEB_ADMIN_USER", "admin")
    System.put_env("AUTOMATA_WEB_ADMIN_PASSWORD", "supersecret")

    conn =
      post(conn, ~p"/login", %{
        "username" => "admin",
        "password" => "supersecret"
      })

    assert redirected_to(conn) == "/dashboard"
  after
    System.delete_env("AUTOMATA_WEB_ADMIN_USER")
    System.delete_env("AUTOMATA_WEB_ADMIN_PASSWORD")
  end
end
