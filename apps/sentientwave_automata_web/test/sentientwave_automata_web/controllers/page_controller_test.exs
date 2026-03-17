defmodule SentientwaveAutomataWeb.PageControllerTest do
  use SentientwaveAutomataWeb.ConnCase

  import Plug.Test, only: [init_test_session: 2]

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET / redirects to dashboard when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/")

    assert redirected_to(conn) == "/dashboard"
  end

  test "GET /dashboard renders dashboard when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/dashboard")

    assert html_response(conn, 200) =~ "Admin Dashboard"
  end

  test "GET /settings/llm renders llm page when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/llm")

    assert html_response(conn, 200) =~ "LLM Provider Management"
  end

  test "GET /settings/tools renders tools page when authenticated", %{conn: conn} do
    conn =
      conn
      |> init_test_session(automata_admin_authenticated: true)
      |> get(~p"/settings/tools")

    assert html_response(conn, 200) =~ "Tool Management"
  end
end
