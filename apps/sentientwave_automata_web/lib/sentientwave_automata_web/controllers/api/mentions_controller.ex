defmodule SentientwaveAutomataWeb.API.MentionsController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Agents.MentionDispatcher

  def create(conn, params) do
    payload = %{
      room_id: Map.get(params, "room_id", ""),
      sender_mxid: Map.get(params, "sender_mxid", ""),
      message_id: Map.get(params, "message_id", ""),
      body: Map.get(params, "body", ""),
      raw_event: Map.get(params, "raw_event", %{}),
      metadata: Map.get(params, "metadata", %{})
    }

    case MentionDispatcher.dispatch(payload) do
      {:ok, result} ->
        conn
        |> put_status(:created)
        |> json(%{data: result})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end
end
