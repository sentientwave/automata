defmodule SentientwaveAutomataWeb.SessionController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomataWeb.AdminAuth

  def new(conn, _params) do
    if AdminAuth.authenticated?(conn) do
      redirect(conn, to: "/dashboard")
    else
      render(conn, :new,
        default_user: AdminAuth.expected_username(),
        password_configured?: AdminAuth.configured_password?(),
        insecure_default?: AdminAuth.insecure_default?()
      )
    end
  end

  def create(conn, %{"username" => username, "password" => password}) do
    if AdminAuth.valid_credentials?(username, password) do
      conn
      |> configure_session(renew: true)
      |> AdminAuth.login()
      |> put_flash(:info, "Admin session established.")
      |> redirect(to: "/dashboard")
    else
      conn
      |> put_flash(:error, "Invalid admin credentials.")
      |> redirect(to: "/login")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Username and password are required.")
    |> redirect(to: "/login")
  end

  def delete(conn, _params) do
    conn
    |> AdminAuth.logout()
    |> configure_session(drop: true)
    |> put_flash(:info, "Logged out.")
    |> redirect(to: "/login")
  end
end
