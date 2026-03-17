defmodule SentientwaveAutomataWeb.AdminAuth do
  @moduledoc """
  Admin authentication settings + session helpers for the web console.
  """

  import Plug.Conn

  alias SentientwaveAutomata.System.Status

  @session_key :automata_admin_authenticated
  @default_admin_user "admin"

  @spec authenticated?(Plug.Conn.t()) :: boolean()
  def authenticated?(conn), do: get_session(conn, @session_key) == true

  @spec login(Plug.Conn.t()) :: Plug.Conn.t()
  def login(conn), do: put_session(conn, @session_key, true)

  @spec logout(Plug.Conn.t()) :: Plug.Conn.t()
  def logout(conn), do: delete_session(conn, @session_key)

  @spec expected_username() :: String.t()
  def expected_username do
    System.get_env("AUTOMATA_WEB_ADMIN_USER") ||
      matrix_localpart() ||
      @default_admin_user
  end

  @spec expected_password() :: String.t()
  def expected_password do
    System.get_env("AUTOMATA_WEB_ADMIN_PASSWORD") ||
      matrix_admin_password() ||
      ""
  end

  @spec authenticate(String.t() | nil, String.t() | nil) :: boolean()
  def authenticate(username, password) do
    secure_compare(to_string(username || ""), expected_username()) and
      secure_compare(to_string(password || ""), expected_password())
  end

  @spec valid_credentials?(String.t() | nil, String.t() | nil) :: boolean()
  def valid_credentials?(username, password), do: authenticate(username, password)

  @spec configured_password?() :: boolean()
  def configured_password? do
    expected_password()
    |> String.trim()
    |> case do
      "" -> false
      _ -> true
    end
  end

  @spec insecure_default?() :: boolean()
  def insecure_default? do
    expected_password() in ["", "change-this"]
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right) do
    Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_, _), do: false

  defp matrix_localpart do
    Status.summary(disable_checks: true)
    |> Map.get(:matrix_admin_user, "")
    |> String.trim()
    |> case do
      "@" <> rest ->
        rest
        |> String.split(":", parts: 2)
        |> List.first()

      _ ->
        nil
    end
  end

  defp matrix_admin_password do
    Status.summary(disable_checks: true)
    |> Map.get(:matrix_admin_password, "")
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end
end
