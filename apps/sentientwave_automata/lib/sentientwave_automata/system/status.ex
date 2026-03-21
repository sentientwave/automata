defmodule SentientwaveAutomata.System.Status do
  @moduledoc """
  Runtime status helpers for local and all-in-one deployments.
  """

  @connection_info_path "/data/connection-info.txt"

  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    info_path = Keyword.get(opts, :connection_info_path, @connection_info_path)
    info = parse_connection_info(info_path)
    disable_checks = Keyword.get(opts, :disable_checks, false)

    matrix_url = Map.get(info, :matrix_url, env("MATRIX_URL", "http://localhost:8008"))
    automata_url = Map.get(info, :automata_url, env("AUTOMATA_URL", "http://localhost:4000"))
    temporal_url = env("TEMPORAL_UI_URL", "http://localhost:8233")
    automata_check_url = add_check_path(automata_url, "/api/v1/workflows")

    %{
      company_name: Map.get(info, :company_name, env("COMPANY_NAME", "SentientWave")),
      group_name: Map.get(info, :group_name, env("GROUP_NAME", "Core Team")),
      matrix_url: matrix_url,
      automata_url: automata_url,
      temporal_ui_url: temporal_url,
      matrix_admin_user: Map.get(info, :matrix_admin_user, ""),
      matrix_admin_password: Map.get(info, :matrix_admin_password, ""),
      room_alias: Map.get(info, :room_alias, ""),
      governance_room_alias:
        Map.get(
          info,
          :governance_room_alias,
          env("MATRIX_GOVERNANCE_ROOM_ALIAS", "governance")
        ),
      invite_password: Map.get(info, :invite_password, ""),
      invite_users: env("MATRIX_INVITE_USERS", ""),
      homeserver_domain: env("MATRIX_HOMESERVER_DOMAIN", "localhost"),
      source: if(map_size(info) > 0, do: "connection-info", else: "env"),
      services: %{
        automata: service_status(automata_check_url, disable_checks),
        matrix: service_status(matrix_url, disable_checks),
        temporal_ui: service_status(temporal_url, disable_checks)
      }
    }
  end

  defp parse_connection_info(path) do
    if File.exists?(path) do
      path
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
          "company" -> Map.put(acc, :company_name, value)
          "group" -> Map.put(acc, :group_name, value)
          "matrix url" -> Map.put(acc, :matrix_url, value)
          "matrix admin user" -> Map.put(acc, :matrix_admin_user, value)
          "matrix admin password" -> Map.put(acc, :matrix_admin_password, value)
          "room alias" -> Map.put(acc, :room_alias, value)
          "governance room alias" -> Map.put(acc, :governance_room_alias, value)
          "invite password" -> Map.put(acc, :invite_password, value)
          "automata url" -> Map.put(acc, :automata_url, value)
          _ -> acc
        end

      _ ->
        acc
    end
  end

  defp service_status(_url, true), do: "skipped"

  defp service_status(url, false) do
    request = {String.to_charlist(url), []}
    http_options = [timeout: 200, connect_timeout: 200]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_, status, _}, _, _}} when status in 200..399 -> "ok"
      {:ok, {{_, status, _}, _, _}} -> "error:#{status}"
      {:error, reason} -> "unreachable:#{inspect(reason)}"
    end
  end

  defp add_check_path(base_url, path) do
    uri = URI.parse(base_url)
    URI.to_string(%URI{uri | path: path, query: nil, fragment: nil})
  end

  defp env(key, default), do: System.get_env(key, default)
end
