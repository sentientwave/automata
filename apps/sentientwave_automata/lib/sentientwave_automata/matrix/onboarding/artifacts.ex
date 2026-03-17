defmodule SentientwaveAutomata.Matrix.Onboarding.Artifacts do
  @moduledoc """
  Builds per-user onboarding artifacts for Matrix client setup.
  """

  @qr_base_default "https://api.qrserver.com/v1/create-qr-code/"

  @spec build(map(), keyword()) :: map()
  def build(status, opts \\ []) do
    homeserver_domain =
      Keyword.get(
        opts,
        :homeserver_domain,
        System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")
      )

    users_input = Keyword.get(opts, :users_input, default_users_input(status))
    include_passwords = Keyword.get(opts, :include_passwords, false)

    users =
      users_input
      |> parse_users(homeserver_domain)
      |> Enum.map(&build_artifact(&1, status, include_passwords))

    %{
      users_input: users_input,
      homeserver_domain: homeserver_domain,
      include_passwords: include_passwords,
      users: users
    }
  end

  defp default_users_input(status) do
    admin = Map.get(status, :matrix_admin_user, "")

    invited =
      System.get_env("MATRIX_INVITE_USERS", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    ([admin] ++ invited)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(",")
  end

  defp parse_users(input, homeserver_domain) do
    input
    |> String.split(~r/[\n,\s]+/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&normalize_mxid(&1, homeserver_domain))
    |> Enum.uniq()
  end

  defp normalize_mxid(raw, homeserver_domain) do
    cond do
      String.starts_with?(raw, "@") and String.contains?(raw, ":") ->
        raw

      String.starts_with?(raw, "@") ->
        "#{raw}:#{homeserver_domain}"

      true ->
        "@#{raw}:#{homeserver_domain}"
    end
  end

  defp build_artifact(mxid, status, include_passwords) do
    matrix_url = Map.get(status, :matrix_url, "http://localhost:8008")
    automata_url = Map.get(status, :automata_url, "http://localhost:4000")
    room_alias = Map.get(status, :room_alias, "")
    password = if(include_passwords, do: resolve_password(mxid, status), else: "")

    password_display =
      if(include_passwords, do: password, else: "(hidden until explicitly enabled)")

    login_url =
      "https://app.element.io/#/login?homeserver=#{URI.encode_www_form(matrix_url)}&username=#{URI.encode_www_form(mxid)}"

    room_url =
      if room_alias == "" do
        ""
      else
        "https://matrix.to/#/#{URI.encode_www_form(room_alias)}"
      end

    onboarding_url = onboarding_url(automata_url, mxid, matrix_url, room_alias, password)

    %{
      mxid: mxid,
      password: password,
      password_display: password_display,
      matrix_url: matrix_url,
      room_alias: room_alias,
      login_url: login_url,
      room_url: room_url,
      onboarding_url: onboarding_url,
      login_qr_url: qr_url(onboarding_url),
      room_qr_url: qr_url(room_url)
    }
  end

  defp resolve_password(mxid, status) do
    if mxid == Map.get(status, :matrix_admin_user, "") do
      Map.get(status, :matrix_admin_password, "")
    else
      Map.get(status, :invite_password, "")
    end
  end

  defp onboarding_url(automata_url, mxid, matrix_url, room_alias, password) do
    base = String.trim_trailing(automata_url, "/") <> "/onboarding/user"

    query =
      URI.encode_query(%{
        "mxid" => mxid,
        "password" => password,
        "homeserver_url" => matrix_url,
        "room_alias" => room_alias
      })

    "#{base}?#{query}"
  end

  defp qr_url(""), do: ""

  defp qr_url(payload) do
    base = System.get_env("AUTOMATA_QR_BASE_URL", @qr_base_default)
    "#{base}?size=220x220&data=#{URI.encode_www_form(payload)}"
  end
end
