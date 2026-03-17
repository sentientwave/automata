defmodule SentientwaveAutomataWeb.Plugs.RequireAdminAuth do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  alias SentientwaveAutomataWeb.AdminAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    if AdminAuth.authenticated?(conn) do
      conn
    else
      conn
      |> put_flash(:error, "Admin sign-in required.")
      |> redirect(to: "/login")
      |> halt()
    end
  end
end
