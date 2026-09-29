defmodule SentientwaveAutomata.System.Status do
  @moduledoc """
  Runtime status helpers for local and all-in-one deployments.
  """

  require Logger

  @connection_info_path "/data/connection-info.txt"
  alias SentientwaveAutomata.Settings

  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    info_path = Keyword.get(opts, :connection_info_path, @connection_info_path)
    info = parse_connection_info(info_path)
    disable_checks = Keyword.get(opts, :disable_checks, false)

    matrix_url = Map.get(info, :matrix_url, env("MATRIX_URL", "http://localhost:8008"))
    automata_url = Map.get(info, :automata_url, env("AUTOMATA_URL", "http://localhost:4000"))

    # The public Temporal UI location varies by deployment (in-cluster service,
    # NodePort, localhost dev); probe candidates in order instead of hardcoding.
    temporal_urls =
      [
        env("TEMPORAL_UI_URL", ""),
        "http://automata-temporal-web:8088",
        "http://localhost:8088",
        "http://localhost:8233"
      ]
      |> Enum.reject(&(&1 == ""))

    %{
      company_name: Map.get(info, :company_name, env("COMPANY_NAME", "SentientWave")),
      group_name: Map.get(info, :group_name, env("GROUP_NAME", "Core Team")),
      matrix_url: matrix_url,
      automata_url: automata_url,
      temporal_ui_url: temporal_urls |> List.first() |> to_string(),
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
      element_web_url: presence_env("ELEMENT_WEB_URL"),
      temporal_ui_public_url:
        presence_env("TEMPORAL_UI_PUBLIC_URL") ||
          temporal_urls |> List.first() |> to_string(),
      federation: Settings.federation_effective(),
      source: if(map_size(info) > 0, do: "connection-info", else: "env"),
      services: %{
        # /login is unauthenticated; /api/v1/workflows requires a token and
        # always reported error:401.
        automata:
          service_status(
            Enum.uniq([add_check_path(automata_url, "/login"), automata_url]),
            disable_checks
          ),
        matrix: service_status(List.wrap(matrix_url), disable_checks),
        temporal_ui: service_status(temporal_urls, disable_checks)
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

  defp service_status(_urls, true), do: "skipped"

  # Probes candidate URLs in order and reports the friendliest accurate state:
  # "ok" if any candidate answers, otherwise "error:<code>" / "unreachable".
  # Raw transport exceptions are logged, never rendered into the UI.
  defp service_status(urls, false) when is_list(urls) do
    urls
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.reduce_while(%{result: "unreachable"}, fn url, acc ->
      case ping(url) do
        {:ok, _status} ->
          {:halt, %{result: "ok"}}

        {:error, {:http, code}} ->
          # remember the HTTP error but keep probing other candidates
          {:cont, if(acc.result == "unreachable", do: %{result: "error:#{code}"}, else: acc)}

        {:error, :unreachable} ->
          Logger.warning("system_status probe failed url=#{url}")
          {:cont, acc}
      end
    end)
    |> Map.get(:result)
  end

  defp ping(url) do
    case Req.get(
           url: url,
           receive_timeout: 1_000,
           connect_options: [timeout: 1_000],
           decode_body: false,
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..399 -> {:ok, status}
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, _reason} -> {:error, :unreachable}
    end
  end

  defp add_check_path(base_url, path) do
    uri = URI.parse(base_url)
    URI.to_string(%URI{uri | path: path, query: nil, fragment: nil})
  end

  defp env(key, default), do: System.get_env(key, default)

  defp presence_env(key) do
    case System.get_env(key) do
      nil -> ""
      value -> String.trim(value)
    end
  end
end
