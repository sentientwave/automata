defmodule SentientwaveAutomataWeb.API.SystemController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.System.Status

  def status(conn, _params) do
    status =
      Status.summary()
      |> Map.put(:matrix_admin_password, nil)
      |> Map.put(:invite_password, nil)

    conn
    |> put_status(:ok)
    |> json(%{data: status})
  end
end
