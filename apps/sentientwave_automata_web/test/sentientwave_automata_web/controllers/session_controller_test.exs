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

  test "POST /login rejects blank password in production when none configured", %{conn: conn} do
    Application.put_env(:sentientwave_automata, :environment, :prod)
    Application.put_env(:sentientwave_automata, :allow_local_fallbacks, false)
    System.delete_env("AUTOMATA_WEB_ADMIN_PASSWORD")
    System.put_env("AUTOMATA_WEB_ADMIN_USER", "admin")

    # Fail closed: with no admin password configured, (admin, "") must not
    # grant access to the console.
    conn =
      post(conn, ~p"/login", %{"username" => "admin", "password" => ""})

    assert redirected_to(conn) == "/login"
  after
    # restore the test-env defaults (config_env() == :test, no fallbacks)
    Application.put_env(:sentientwave_automata, :environment, :test)
    Application.put_env(:sentientwave_automata, :allow_local_fallbacks, false)
    System.delete_env("AUTOMATA_WEB_ADMIN_PASSWORD")
    System.delete_env("AUTOMATA_WEB_ADMIN_USER")
  end
end
