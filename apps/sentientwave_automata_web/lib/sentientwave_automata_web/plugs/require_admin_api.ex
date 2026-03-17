defmodule SentientwaveAutomataWeb.Plugs.RequireAdminAPI do
  @moduledoc false
  import Phoenix.Controller
  import Plug.Conn

  alias SentientwaveAutomataWeb.AdminAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    if AdminAuth.authenticated?(conn) do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> json(%{error: "admin_auth_required"})
      |> halt()
    end
  end
end
