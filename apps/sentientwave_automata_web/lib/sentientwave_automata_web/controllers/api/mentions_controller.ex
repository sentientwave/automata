defmodule SentientwaveAutomataWeb.API.MentionsController do
  use SentientwaveAutomataWeb, :controller

  alias SentientwaveAutomata.Agents.MentionDispatcher

  def create(conn, params) do
    metadata =
      params
      |> Map.get("metadata", %{})
      |> Map.put_new("source", "mentions_api")
      |> Map.put("remote_ip", remote_ip(conn))
      |> Map.put("conversation_scope", conversation_scope(params))

    payload = %{
      room_id: Map.get(params, "room_id", ""),
      sender_mxid: Map.get(params, "sender_mxid", ""),
      message_id: Map.get(params, "message_id", ""),
      body: Map.get(params, "body", ""),
      raw_event: Map.get(params, "raw_event", %{}),
      remote_ip: remote_ip(conn),
      conversation_scope: conversation_scope(params),
      metadata: metadata
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

  defp conversation_scope(params) do
    cond do
      Map.get(params, "conversation_scope") in ["private_message", "dm", "direct"] ->
        "private_message"

      Map.get(params, "private_message") in [true, "true", "1", 1, "on"] ->
        "private_message"

      String.trim(Map.get(params, "room_id", "")) != "" ->
        "room"

      true ->
        "unknown"
    end
  end

  defp remote_ip(conn) do
    forwarded =
      conn
      |> get_req_header("x-forwarded-for")
      |> List.first()
      |> case do
        nil -> nil
        value -> value |> String.split(",", parts: 2) |> List.first() |> String.trim()
      end

    cond do
      is_binary(forwarded) and forwarded != "" ->
        forwarded

      is_tuple(conn.remote_ip) ->
        conn.remote_ip |> :inet.ntoa() |> to_string()

      true ->
        ""
    end
  end
end
