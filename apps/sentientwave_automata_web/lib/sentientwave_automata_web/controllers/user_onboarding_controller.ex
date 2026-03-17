defmodule SentientwaveAutomataWeb.UserOnboardingController do
  use SentientwaveAutomataWeb, :controller

  def show(conn, params) do
    mxid = Map.get(params, "mxid", "") |> String.trim()

    password =
      Map.get(params, "password", "")
      |> String.trim()
      |> case do
        "" -> "(password intentionally hidden by admin)"
        value -> value
      end

    homeserver_url = Map.get(params, "homeserver_url", "http://localhost:8008") |> String.trim()
    room_alias = Map.get(params, "room_alias", "") |> String.trim()

    render(conn, :show,
      mxid: mxid,
      password: password,
      homeserver_url: homeserver_url,
      room_alias: room_alias,
      room_link: matrix_to_link(room_alias),
      profile_link: matrix_to_link(mxid),
      element_login_link: element_login_link(homeserver_url, mxid)
    )
  end

  defp matrix_to_link(""), do: nil
  defp matrix_to_link(value), do: "https://matrix.to/#/" <> URI.encode(value)

  defp element_login_link("", _mxid), do: nil
  defp element_login_link(_homeserver_url, ""), do: nil

  defp element_login_link(homeserver_url, mxid) do
    "https://app.element.io/#/login?homeserver=" <>
      URI.encode_www_form(homeserver_url) <>
      "&username=" <> URI.encode_www_form(mxid)
  end
end
