defmodule SentientwaveAutomata.Matrix.SynapseAdmin do
  @moduledoc """
  Minimal Synapse admin API client used for user reconciliation.
  """
  require Logger

  @membership_cache_key {:sentientwave_automata, :matrix_membership_reconcile}
  @invite_poll_cache_key {:sentientwave_automata, :matrix_invite_poll}

  @spec reconcile_user(map(), keyword()) :: :ok | {:error, term()}
  def reconcile_user(user, opts \\ []) do
    case admin_token() do
      {:ok, token} ->
        with :ok <- upsert_user(token, user, opts),
             :ok <- ensure_default_room_membership(token, user) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, :admin_login_failed} ->
        # Fallback path for drifted admin credentials on reused Matrix volumes.
        # This ensures user presence can still be reconciled via shared-secret registration.
        with :ok <- register_with_shared_secret(user),
             :ok <- ensure_default_room_membership_without_admin(user) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec deactivate_user(String.t()) :: :ok | {:error, term()}
  def deactivate_user(localpart) when is_binary(localpart) do
    mxid = "@#{normalize_localpart(localpart)}:#{matrix_domain()}"
    encoded_mxid = URI.encode_www_form(mxid)
    base = matrix_url()

    with {:ok, token} <- admin_token(),
         {:ok, code, _body} <-
           request(
             :put,
             "#{base}/_synapse/admin/v2/users/#{encoded_mxid}",
             auth_header(token),
             %{"deactivated" => true}
           ),
         true <- code in 200..299 do
      :ok
    else
      false -> {:error, :deactivate_http_error}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :deactivate_failed}
    end
  end

  @spec invite_localpart_to_room(String.t(), String.t()) :: :ok | {:error, term()}
  def invite_localpart_to_room(localpart, room_id)
      when is_binary(localpart) and is_binary(room_id) do
    normalized = normalize_localpart(localpart)
    mxid = "@#{normalized}:#{matrix_domain()}"

    with {:ok, inviter_token} <- invite_operator_token(),
         :ok <- invite_user_to_room(inviter_token, room_id, mxid),
         {:ok, user_token, _mxid} <- login_user(normalized, directory_password(normalized)),
         :ok <- join_room_by_id(user_token, room_id) do
      :ok
    else
      {:error, {:user_login_failed, 429, body}} ->
        backoff_invite_poll(normalized, body)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec reconcile_operator_invites() :: :ok | {:error, term()}
  def reconcile_operator_invites do
    with {:ok, token} <- login_operator_user() do
      accept_pending_invites(matrix_agent_user(), token)
    end
  end

  defp admin_token do
    base = matrix_url()
    admin_user = System.get_env("MATRIX_ADMIN_USER", "admin")
    admin_password = System.get_env("MATRIX_ADMIN_PASSWORD", "")

    payload = %{
      "type" => "m.login.password",
      "identifier" => %{"type" => "m.id.user", "user" => admin_user},
      "password" => admin_password
    }

    with {:ok, 200, body} <- request(:post, "#{base}/_matrix/client/v3/login", [], payload),
         %{"access_token" => token} <- Jason.decode!(body) do
      {:ok, token}
    else
      _ -> {:error, :admin_login_failed}
    end
  end

  defp upsert_user(token, user, opts) do
    mxid = "@#{user.localpart}:#{matrix_domain()}"
    base = matrix_url()
    encoded_mxid = URI.encode_www_form(mxid)
    force_password? = Keyword.get(opts, :force_password, false)

    with {:ok, exists?} <- user_exists?(token, encoded_mxid) do
      cond do
        exists? and not reconcile_update_existing_users?() ->
          # Default-safe mode: avoid mutating existing Matrix accounts on reconcile.
          # This prevents accidental session churn/logouts from periodic reconciliation.
          :ok

        true ->
          payload = %{
            "admin" => user.admin,
            "deactivated" => false,
            "displayname" => user.display_name,
            # Reconciliation should never forcibly invalidate active Matrix sessions.
            "logout_devices" => false
          }

          payload =
            if exists? and not force_password? and not reconcile_rotate_passwords?() do
              payload
            else
              Map.put(payload, "password", user.password)
            end

          case request(
                 :put,
                 "#{base}/_synapse/admin/v2/users/#{encoded_mxid}",
                 auth_header(token),
                 payload
               ) do
            {:ok, code, _body} when code in 200..299 -> :ok
            {:ok, code, body} -> {:error, {:synapse_error, code, body}}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp user_exists?(token, encoded_mxid) do
    base = matrix_url()

    case request(:get, "#{base}/_synapse/admin/v2/users/#{encoded_mxid}", auth_header(token), nil) do
      {:ok, 200, _body} -> {:ok, true}
      {:ok, 404, _body} -> {:ok, false}
      {:ok, code, body} -> {:error, {:synapse_lookup_error, code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_default_room_membership(_token, %{kind: kind}) when kind not in [:agent, "agent"],
    do: :ok

  defp ensure_default_room_membership(token, user) do
    aliases = default_room_aliases()
    skip_default = skip_default_membership_reconcile?(user)

    needs_default =
      aliases != [] and not skip_default and not membership_recently_reconciled?(user.localpart)

    needs_invite_poll = invite_poll_due?(user.localpart)

    if not needs_default and not needs_invite_poll do
      :ok
    else
      with {:ok, user_token, user_mxid} <- login_reconcile_user(user),
           :ok <-
             maybe_ensure_membership_for_aliases(
               needs_default,
               token,
               user_token,
               user_mxid,
               aliases
             ),
           :ok <- maybe_accept_pending_invites(needs_invite_poll, user.localpart, user_token) do
        if needs_default, do: mark_membership_reconciled(user.localpart)
        if needs_invite_poll, do: mark_invite_polled(user.localpart)
        :ok
      else
        {:error, {:user_login_failed, 429, body}} ->
          # Synapse rate-limits login aggressively; avoid failing whole reconcile cycle.
          backoff_invite_poll(user.localpart, body)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_default_room_membership_without_admin(%{kind: kind})
       when kind not in [:agent, "agent"],
       do: :ok

  defp ensure_default_room_membership_without_admin(user) do
    aliases = default_room_aliases()
    skip_default = skip_default_membership_reconcile?(user)

    needs_default =
      aliases != [] and not skip_default and not membership_recently_reconciled?(user.localpart)

    needs_invite_poll = invite_poll_due?(user.localpart)

    if not needs_default and not needs_invite_poll do
      :ok
    else
      with {:ok, inviter_token} <- login_operator_user(),
           {:ok, user_token, user_mxid} <- login_reconcile_user(user),
           :ok <-
             maybe_ensure_membership_for_aliases(
               needs_default,
               inviter_token,
               user_token,
               user_mxid,
               aliases
             ),
           :ok <- maybe_accept_pending_invites(needs_invite_poll, user.localpart, user_token) do
        if needs_default, do: mark_membership_reconciled(user.localpart)
        if needs_invite_poll, do: mark_invite_polled(user.localpart)
        :ok
      else
        {:error, {:user_login_failed, 429, body}} ->
          backoff_invite_poll(user.localpart, body)
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp maybe_ensure_membership_for_aliases(false, _token, _user_token, _user_mxid, _aliases),
    do: :ok

  defp maybe_ensure_membership_for_aliases(true, token, user_token, user_mxid, aliases),
    do: ensure_membership_for_aliases(token, user_token, user_mxid, aliases)

  defp maybe_accept_pending_invites(false, _localpart, _user_token), do: :ok

  defp maybe_accept_pending_invites(true, localpart, user_token),
    do: accept_pending_invites(localpart, user_token)

  defp ensure_membership_for_aliases(_admin_token, _user_token, _user_mxid, []), do: :ok

  defp ensure_membership_for_aliases(admin_token, user_token, user_mxid, [alias_full | rest]) do
    with :ok <- invite_user_to_room(admin_token, alias_full, user_mxid),
         :ok <- join_room(user_token, alias_full) do
      ensure_membership_for_aliases(admin_token, user_token, user_mxid, rest)
    else
      {:error, {:invite_http_error, 403, _}} ->
        # Already invited or already joined with insufficient power in some Synapse configs.
        ensure_membership_for_aliases(admin_token, user_token, user_mxid, rest)

      {:error, {:join_http_error, 403, _}} ->
        {:error, {:join_forbidden, alias_full}}

      {:error, {:join_http_error, 404, _}} ->
        {:error, {:join_room_not_found, alias_full}}

      {:error, reason} ->
        {:error, {:default_room_membership_failed, alias_full, reason}}
    end
  end

  defp invite_user_to_room(token, alias_full, user_mxid) do
    base = matrix_url()
    encoded_room = URI.encode_www_form(alias_full)

    case request(
           :post,
           "#{base}/_matrix/client/v3/rooms/#{encoded_room}/invite",
           auth_header(token),
           %{"user_id" => user_mxid}
         ) do
      {:ok, code, _body} when code in [200, 201] -> :ok
      {:ok, 409, _body} -> :ok
      {:ok, code, body} -> {:error, {:invite_http_error, code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp join_room(token, alias_full) do
    base = matrix_url()
    encoded_room = URI.encode_www_form(alias_full)

    case request(
           :post,
           "#{base}/_matrix/client/v3/join/#{encoded_room}",
           auth_header(token),
           %{}
         ) do
      {:ok, code, _body} when code in [200, 201] ->
        :ok

      {:ok, 403, body} ->
        if already_in_room?(body), do: :ok, else: {:error, {:join_http_error, 403, body}}

      {:ok, code, body} ->
        {:error, {:join_http_error, code, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp accept_pending_invites(localpart, user_token) do
    filter = URI.encode_www_form(Jason.encode!(%{"room" => %{"timeline" => %{"limit" => 1}}}))
    sync_url = "#{matrix_url()}/_matrix/client/v3/sync?timeout=0&filter=#{filter}"

    with {:ok, 200, body} <- request(:get, sync_url, auth_header(user_token), nil),
         {:ok, payload} <- Jason.decode(body) do
      invited =
        payload
        |> Map.get("rooms", %{})
        |> Map.get("invite", %{})

      invited_room_ids =
        invited
        |> Map.keys()

      result =
        invited_room_ids
        |> Enum.reduce_while(:ok, fn room_id, :ok ->
          case join_room_by_id(user_token, room_id) do
            :ok ->
              {:cont, :ok}

            {:error, {:join_http_error, 429, body}} ->
              backoff_invite_poll(localpart, body)
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, {:invite_accept_failed, room_id, reason}}}
          end
        end)

      if result == :ok and invited_room_ids != [] do
        Logger.info(
          "matrix_invites_accepted localpart=#{normalize_localpart(localpart)} count=#{length(invited_room_ids)}"
        )
      end

      result
    else
      {:ok, 429, body} ->
        backoff_invite_poll(localpart, body)
        :ok

      {:ok, code, body} ->
        {:error, {:invite_sync_http_error, code, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp join_room_by_id(token, room_id) do
    base = matrix_url()
    encoded_room = URI.encode_www_form(room_id)

    case request(
           :post,
           "#{base}/_matrix/client/v3/rooms/#{encoded_room}/join",
           auth_header(token),
           %{}
         ) do
      {:ok, code, _body} when code in [200, 201] ->
        :ok

      {:ok, 403, body} ->
        if already_in_room?(body), do: :ok, else: {:error, {:join_http_error, 403, body}}

      {:ok, code, body} ->
        {:error, {:join_http_error, code, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp already_in_room?(body) when is_binary(body) do
    String.contains?(String.downcase(body), "already in the room")
  end

  defp already_in_room?(_), do: false

  defp login_user(localpart, password) do
    payload = %{
      "type" => "m.login.password",
      "identifier" => %{"type" => "m.id.user", "user" => localpart},
      "password" => password
    }

    case request(:post, "#{matrix_url()}/_matrix/client/v3/login", [], payload) do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => token, "user_id" => user_id}} ->
            {:ok, token, user_id}

          _ ->
            {:error, :invalid_user_login_response}
        end

      {:ok, code, body} ->
        {:error, {:user_login_failed, code, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp login_operator_user do
    case operator_access_token() do
      {:ok, token} ->
        case validate_operator_token(token) do
          :ok ->
            {:ok, token}

          {:error, _reason} ->
            login_operator_user_with_password()
        end

      {:error, :no_operator_access_token} ->
        login_operator_user_with_password()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp invite_operator_token do
    case admin_token() do
      {:ok, token} -> {:ok, token}
      _ -> login_operator_user()
    end
  end

  defp operator_access_token do
    token =
      System.get_env("MATRIX_AGENT_ACCESS_TOKEN") ||
        read_token_file(
          System.get_env("MATRIX_AGENT_ACCESS_TOKEN_FILE", "/data/matrix/automata-access-token")
        )

    if is_binary(token) and String.trim(token) != "" do
      {:ok, String.trim(token)}
    else
      {:error, :no_operator_access_token}
    end
  end

  defp validate_operator_token(token) when is_binary(token) and token != "" do
    case request(
           :get,
           "#{matrix_url()}/_matrix/client/v3/account/whoami",
           auth_header(token),
           nil
         ) do
      {:ok, 200, _body} -> :ok
      {:ok, 401, _body} -> {:error, :invalid_operator_access_token}
      {:ok, code, body} -> {:error, {:operator_token_validation_failed, code, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_operator_token(_), do: {:error, :invalid_operator_access_token}

  defp login_operator_user_with_password do
    payload = %{
      "type" => "m.login.password",
      "identifier" => %{"type" => "m.id.user", "user" => matrix_agent_user()},
      "password" => matrix_agent_password()
    }

    case request(:post, "#{matrix_url()}/_matrix/client/v3/login", [], payload) do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => token}} -> {:ok, token}
          _ -> {:error, :invalid_operator_login_response}
        end

      {:ok, code, body} ->
        {:error, {:operator_login_failed, code, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp default_room_aliases do
    [
      System.get_env("MATRIX_MAIN_ROOM_ALIAS", "main"),
      System.get_env("MATRIX_RANDOM_ROOM_ALIAS", "random"),
      System.get_env("MATRIX_GOVERNANCE_ROOM_ALIAS", "governance")
    ]
    |> Enum.map(&normalize_alias/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map(fn alias_local -> "##{alias_local}:#{matrix_domain()}" end)
  end

  defp normalize_alias(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("#")
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp auth_header(token), do: [{"authorization", "Bearer #{token}"}]

  defp request(method, url, headers, body_map) when is_map(body_map) do
    body = Jason.encode!(body_map)
    request(method, url, headers, body)
  end

  defp request(method, url, headers, nil) do
    req = {String.to_charlist(url), normalize_headers(headers)}
    opts = [timeout: 1_500, connect_timeout: 1_500]

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} -> {:ok, status, resp_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, url, headers, body) when is_binary(body) do
    http_headers = [{"content-type", "application/json"} | headers] |> normalize_headers()
    req = {String.to_charlist(url), http_headers, ~c"application/json", body}
    opts = [timeout: 1_500, connect_timeout: 1_500]

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} -> {:ok, status, resp_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp matrix_url, do: System.get_env("MATRIX_URL", "http://localhost:8008")
  defp matrix_domain, do: System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")
  defp matrix_agent_user, do: System.get_env("MATRIX_AGENT_USER", "automata")
  defp matrix_agent_password, do: System.get_env("MATRIX_AGENT_PASSWORD", "changeme123")
  defp normalize_localpart(localpart), do: localpart |> String.trim() |> String.trim_leading("@")

  defp reconcile_update_existing_users?,
    do:
      System.get_env("MATRIX_RECONCILE_UPDATE_EXISTING_USERS", "false") in [
        "1",
        "true",
        "TRUE",
        "yes",
        "YES"
      ]

  defp reconcile_rotate_passwords?,
    do:
      System.get_env("MATRIX_RECONCILE_ROTATE_PASSWORDS", "false") in [
        "1",
        "true",
        "TRUE",
        "yes",
        "YES"
      ]

  defp normalize_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp read_token_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp directory_password(localpart) do
    case SentientwaveAutomata.Matrix.Directory.get_user(localpart) do
      %{password: pw} when is_binary(pw) -> pw
      _ -> ""
    end
  end

  defp skip_default_membership_reconcile?(user) do
    normalize_localpart(user.localpart) == normalize_localpart(matrix_agent_user())
  end

  defp login_reconcile_user(user) do
    if skip_default_membership_reconcile?(user) do
      with {:ok, token} <- login_operator_user() do
        {:ok, token, "@#{normalize_localpart(user.localpart)}:#{matrix_domain()}"}
      end
    else
      login_user(user.localpart, user.password)
    end
  end

  defp membership_recently_reconciled?(localpart) do
    now = System.system_time(:millisecond)
    cache = :persistent_term.get(@membership_cache_key, %{})
    key = normalize_localpart(localpart)

    case Map.get(cache, key) do
      ts when is_integer(ts) -> now - ts < membership_ttl_ms()
      _ -> false
    end
  end

  defp mark_membership_reconciled(localpart) do
    now = System.system_time(:millisecond)
    cache = :persistent_term.get(@membership_cache_key, %{})
    key = normalize_localpart(localpart)
    :persistent_term.put(@membership_cache_key, Map.put(cache, key, now))
    :ok
  end

  defp membership_ttl_ms do
    System.get_env("MATRIX_MEMBERSHIP_RECONCILE_TTL_MS", "3600000")
    |> String.to_integer()
  rescue
    _ -> 3_600_000
  end

  defp invite_poll_due?(localpart) do
    now = System.system_time(:millisecond)
    cache = :persistent_term.get(@invite_poll_cache_key, %{})
    key = normalize_localpart(localpart)

    case Map.get(cache, key) do
      ts when is_integer(ts) -> now >= ts
      _ -> true
    end
  end

  defp mark_invite_polled(localpart) do
    set_next_invite_poll(localpart, System.system_time(:millisecond) + invite_poll_interval_ms())
    :ok
  end

  defp backoff_invite_poll(localpart, body) do
    retry_ms = retry_after_ms(body)
    set_next_invite_poll(localpart, System.system_time(:millisecond) + retry_ms)
    :ok
  end

  defp set_next_invite_poll(localpart, next_at_ms) do
    cache = :persistent_term.get(@invite_poll_cache_key, %{})
    key = normalize_localpart(localpart)
    :persistent_term.put(@invite_poll_cache_key, Map.put(cache, key, next_at_ms))
  end

  defp invite_poll_interval_ms do
    System.get_env("MATRIX_INVITE_POLL_INTERVAL_MS", "60000")
    |> String.to_integer()
  rescue
    _ -> 60_000
  end

  defp retry_after_ms(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"retry_after_ms" => ms}} when is_integer(ms) and ms > 0 -> ms
      _ -> invite_poll_interval_ms()
    end
  end

  defp retry_after_ms(_), do: invite_poll_interval_ms()

  defp register_with_shared_secret(user) do
    case System.find_executable("register_new_matrix_user") do
      nil ->
        {:error, :register_new_matrix_user_not_available}

      _path ->
        args =
          [
            "-u",
            user.localpart,
            "-p",
            user.password
          ] ++
            admin_flag(user.admin) ++
            [
              "--exists-ok",
              "-c",
              System.get_env("MATRIX_CONFIG_PATH", "/data/matrix/homeserver.yaml"),
              matrix_url()
            ]

        case System.cmd("register_new_matrix_user", args, stderr_to_stdout: true) do
          {output, 0} ->
            _ = output
            :ok

          {output, _code} ->
            {:error, {:shared_secret_register_failed, output}}
        end
    end
  end

  defp admin_flag(true), do: ["-a"]
  defp admin_flag(false), do: ["--no-admin"]
end
