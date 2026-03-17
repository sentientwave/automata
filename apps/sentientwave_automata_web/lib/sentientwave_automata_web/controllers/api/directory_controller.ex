defmodule SentientwaveAutomataWeb.API.DirectoryController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.Reconciler

  def index(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{data: Directory.list_users()})
  end

  def upsert(conn, params) do
    case Directory.upsert_user(params) do
      {:ok, user} ->
        conn
        |> put_status(:ok)
        |> json(%{data: user})

      {:error, errors} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end

  def reconcile(conn, _params) do
    conn
    |> put_status(:ok)
    |> json(%{data: Reconciler.reconcile()})
  end
end
