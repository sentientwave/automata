defmodule SentientwaveAutomata.Governance.Room do
  @moduledoc """
  Helpers for the dedicated governance Matrix room.
  """

  @connection_info_path "/data/connection-info.txt"
  @default_room_id "!governance:localhost"
  @default_room_alias "governance"

  @spec room_id() :: String.t()
  def room_id do
    connection_info()
    |> Map.get(:governance_room_id, System.get_env("MATRIX_GOVERNANCE_ROOM_ID", @default_room_id))
    |> normalize_value(@default_room_id)
  end

  @spec room_alias() :: String.t()
  def room_alias do
    connection_info()
    |> Map.get(
      :governance_room_alias,
      System.get_env("MATRIX_GOVERNANCE_ROOM_ALIAS", @default_room_alias)
    )
    |> normalize_value(@default_room_alias)
  end

  @spec room?(String.t()) :: boolean()
  def room?(room_id) when is_binary(room_id) do
    trimmed = String.trim(room_id)
    trimmed != "" and trimmed == room_id()
  end

  def room?(_room_id), do: false

  @spec bot_mxid() :: String.t()
  def bot_mxid do
    user = System.get_env("MATRIX_AGENT_USER", "automata")
    domain = System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")

    "@#{user}:#{domain}"
  end

  defp connection_info do
    if File.exists?(@connection_info_path) do
      @connection_info_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.reduce(%{}, &parse_line/2)
    else
      %{}
    end
  end

  defp parse_line(line, acc) do
    case String.split(line, ":", parts: 2) do
      [raw_key, raw_value] ->
        key =
          raw_key
          |> String.trim()
          |> String.downcase()

        value = String.trim(raw_value)

        case key do
          "governance room id" ->
            Map.put(acc, :governance_room_id, value)

          "governance room alias" ->
            Map.put(acc, :governance_room_alias, extract_room_alias(value))

          _ ->
            acc
        end

      _ ->
        acc
    end
  end

  defp extract_room_alias(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("#")
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp normalize_value(value, default) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> default
      trimmed -> trimmed
    end
  end
end
