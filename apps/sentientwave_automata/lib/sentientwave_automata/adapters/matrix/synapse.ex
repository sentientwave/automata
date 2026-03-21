defmodule SentientwaveAutomata.Adapters.Matrix.Synapse do
  @moduledoc """
  Matrix adapter backed by Synapse client APIs.
  """

  require Logger

  @behaviour SentientwaveAutomata.Adapters.Matrix.Behaviour

  alias SentientwaveAutomata.Agents.MentionDispatcher
  alias SentientwaveAutomata.Governance.Dispatcher, as: GovernanceDispatcher

  @token_key {:sentientwave_automata, :matrix_agent_token}

  @impl true
  def post_message(room_id, message, metadata) when is_binary(room_id) and room_id != "" do
    with {:ok, token, sender} <- agent_token() do
      case do_send_message(token, room_id, message) do
        {:ok, status, _body} when status in 200..299 ->
          Logger.info(
            "matrix_synapse_send room=#{room_id} sender=#{sender} meta=#{inspect(metadata)}"
          )

          :ok

        {:ok, 401, _body} ->
          with {:ok, fresh_token, _} <- force_refresh_token(),
               {:ok, status, _body} <- do_send_message(fresh_token, room_id, message),
               true <- status in 200..299 do
            Logger.info(
              "matrix_synapse_send room=#{room_id} sender=#{sender} meta=#{inspect(metadata)}"
            )

            :ok
          else
            false -> {:error, :send_unauthorized_after_refresh}
            {:ok, status, body} -> {:error, {:send_http_error, status, body}}
            {:error, reason} -> {:error, reason}
          end

        {:ok, 429, body} ->
          retry_ms = retry_after_ms(body)
          Process.sleep(retry_ms)

          case do_send_message(token, room_id, message) do
            {:ok, status, _body} when status in 200..299 ->
              Logger.info(
                "matrix_synapse_send room=#{room_id} sender=#{sender} meta=#{inspect(metadata)} retry=429"
              )

              :ok

            {:ok, status, retry_body} ->
              {:error, {:send_http_error, status, retry_body}}

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, status, body} ->
          {:error, {:send_http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def post_message(_room_id, _message, _metadata), do: {:error, :invalid_room_id}

  @impl true
  def set_typing(room_id, typing, timeout_ms, metadata)
      when is_binary(room_id) and room_id != "" and is_boolean(typing) do
    with {:ok, token, sender} <- agent_token() do
      case do_set_typing(token, sender, room_id, typing, timeout_ms) do
        {:ok, status, _body} when status in 200..299 ->
          Logger.info(
            "matrix_synapse_typing room=#{room_id} sender=#{sender} typing=#{typing} meta=#{inspect(metadata)}"
          )

          :ok

        {:ok, 401, _body} ->
          with {:ok, fresh_token, fresh_sender} <- force_refresh_token(),
               {:ok, status, _body} <-
                 do_set_typing(fresh_token, fresh_sender, room_id, typing, timeout_ms),
               true <- status in 200..299 do
            Logger.info(
              "matrix_synapse_typing room=#{room_id} sender=#{fresh_sender} typing=#{typing} meta=#{inspect(metadata)} refresh=true"
            )

            :ok
          else
            false -> {:error, :typing_unauthorized_after_refresh}
            {:ok, status, body} -> {:error, {:typing_http_error, status, body}}
            {:error, reason} -> {:error, reason}
          end

        {:ok, status, body} ->
          {:error, {:typing_http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def set_typing(_room_id, _typing, _timeout_ms, _metadata), do: {:error, :invalid_typing_payload}

  @impl true
  def ingest_event(%{"type" => "m.room.message", "content" => %{"body" => body}} = event)
      when is_binary(body) do
    message = %{
      room_id: Map.get(event, "room_id", ""),
      sender_mxid: Map.get(event, "sender", ""),
      message_id:
        Map.get(event, "event_id", Integer.to_string(System.unique_integer([:positive]))),
      body: body,
      raw_event: event,
      metadata: %{"source" => "matrix_sync", "conversation_scope" => "room"}
    }

    case GovernanceDispatcher.dispatch(message) do
      :pass_through ->
        _ = MentionDispatcher.dispatch(message)
        :ok

      {:governance, _result} ->
        :ok
    end
  end

  def ingest_event(_event), do: :ok

  @spec joined_members(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def joined_members(room_id) when is_binary(room_id) and room_id != "" do
    with {:ok, token, _sender} <- agent_token() do
      url =
        "#{matrix_url()}/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/joined_members"

      case request(:get, url, auth_headers(token), nil) do
        {:ok, status, body} when status in 200..299 ->
          case Jason.decode(body) do
            {:ok, %{"joined" => joined}} when is_map(joined) ->
              {:ok, Map.keys(joined)}

            _ ->
              {:ok, []}
          end

        {:ok, 401, _body} ->
          with {:ok, fresh_token, _sender} <- force_refresh_token(),
               {:ok, status, body} <- request(:get, url, auth_headers(fresh_token), nil),
               true <- status in 200..299,
               {:ok, %{"joined" => joined}} <- Jason.decode(body),
               true <- is_map(joined) do
            {:ok, Map.keys(joined)}
          else
            false -> {:error, :joined_members_unauthorized_after_refresh}
            {:ok, status, body} -> {:error, {:joined_members_http_error, status, body}}
            {:error, reason} -> {:error, reason}
            _ -> {:ok, []}
          end

        {:ok, status, body} ->
          {:error, {:joined_members_http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def joined_members(_room_id), do: {:error, :invalid_room_id}

  @spec sync(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def sync(since \\ nil) do
    with {:ok, token, _sender} <- agent_token() do
      url = sync_url(since)

      case request(:get, url, auth_headers(token), nil) do
        {:ok, status, body} when status in 200..299 ->
          Jason.decode(body)

        {:ok, 401, _body} ->
          with {:ok, fresh_token, _sender} <- force_refresh_token(),
               {:ok, status, body} <- request(:get, url, auth_headers(fresh_token), nil),
               true <- status in 200..299 do
            Jason.decode(body)
          else
            false -> {:error, :sync_unauthorized_after_refresh}
            {:ok, status, body} -> {:error, {:sync_http_error, status, body}}
            {:error, reason} -> {:error, reason}
          end

        {:ok, status, body} ->
          {:error, {:sync_http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec accept_invite(String.t()) :: :ok | {:error, term()}
  def accept_invite(room_id) when is_binary(room_id) and room_id != "" do
    with {:ok, token, sender} <- agent_token() do
      case do_join_room_by_id(token, room_id) do
        {:ok, status, _body} when status in 200..299 ->
          Logger.info("matrix_synapse_join room=#{room_id} sender=#{sender}")
          :ok

        {:ok, 401, _body} ->
          with {:ok, fresh_token, fresh_sender} <- force_refresh_token(),
               {:ok, status, _body} <- do_join_room_by_id(fresh_token, room_id),
               true <- status in 200..299 do
            Logger.info("matrix_synapse_join room=#{room_id} sender=#{fresh_sender} refresh=true")
            :ok
          else
            false -> {:error, :join_unauthorized_after_refresh}
            {:ok, status, body} -> {:error, {:join_http_error, status, body}}
            {:error, reason} -> {:error, reason}
          end

        {:ok, status, body} ->
          {:error, {:join_http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def accept_invite(_room_id), do: {:error, :invalid_room_id}

  defp sync_url(nil),
    do:
      "#{matrix_url()}/_matrix/client/v3/sync?timeout=#{sync_timeout_ms()}&filter=#{URI.encode_www_form(sync_filter())}"

  defp sync_url(since),
    do:
      "#{matrix_url()}/_matrix/client/v3/sync?since=#{URI.encode_www_form(since)}&timeout=#{sync_timeout_ms()}&filter=#{URI.encode_www_form(sync_filter())}"

  defp sync_filter do
    Jason.encode!(%{
      "room" => %{
        "timeline" => %{"types" => ["m.room.message"], "limit" => 50}
      }
    })
  end

  defp do_send_message(token, room_id, message) do
    txn_id = "txn_" <> Integer.to_string(System.unique_integer([:positive]))

    url =
      "#{matrix_url()}/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/send/m.room.message/#{txn_id}"

    payload = %{"msgtype" => "m.text", "body" => message}
    request(:put, url, auth_headers(token), payload)
  end

  defp do_set_typing(token, sender_mxid, room_id, typing, timeout_ms) do
    url =
      "#{matrix_url()}/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/typing/#{URI.encode_www_form(sender_mxid)}"

    payload =
      if typing do
        %{"typing" => true, "timeout" => max(timeout_ms, 500)}
      else
        %{"typing" => false}
      end

    request(:put, url, auth_headers(token), payload)
  end

  defp do_join_room_by_id(token, room_id) do
    url = "#{matrix_url()}/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/join"
    request(:post, url, auth_headers(token), %{})
  end

  defp agent_token do
    case :persistent_term.get(@token_key, nil) do
      %{token: token, sender: sender} when is_binary(token) and is_binary(sender) ->
        {:ok, token, sender}

      _ ->
        with {:ok, token} <- configured_access_token_or_nil(),
             sender <- "@#{matrix_agent_user()}:#{matrix_domain()}" do
          :persistent_term.put(@token_key, %{token: token, sender: sender})
          {:ok, token, sender}
        else
          {:error, :no_configured_access_token} -> force_refresh_token()
        end
    end
  end

  defp force_refresh_token do
    case login_agent() do
      {:ok, token, sender} = ok ->
        :persistent_term.put(@token_key, %{token: token, sender: sender})
        ok

      other ->
        other
    end
  end

  defp login_agent do
    payload = %{
      "type" => "m.login.password",
      "identifier" => %{"type" => "m.id.user", "user" => matrix_agent_user()},
      "password" => matrix_agent_password()
    }

    case request(:post, "#{matrix_url()}/_matrix/client/v3/login", [], payload) do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => token, "user_id" => user_id}} ->
            {:ok, token, user_id}

          {:ok, %{"access_token" => token}} ->
            {:ok, token, "@#{matrix_agent_user()}:#{matrix_domain()}"}

          _ ->
            {:error, :invalid_login_response}
        end

      {:ok, status, body} ->
        {:error, {:agent_login_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp configured_access_token_or_nil do
    token =
      System.get_env("MATRIX_AGENT_ACCESS_TOKEN") ||
        read_token_file(
          System.get_env("MATRIX_AGENT_ACCESS_TOKEN_FILE", "/data/matrix/automata-access-token")
        )

    if is_binary(token) and String.trim(token) != "" do
      {:ok, String.trim(token)}
    else
      {:error, :no_configured_access_token}
    end
  end

  defp read_token_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> content
      _ -> nil
    end
  end

  defp retry_after_ms(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"retry_after_ms" => ms}} when is_integer(ms) and ms > 0 -> ms
      _ -> 1_000
    end
  end

  defp retry_after_ms(_), do: 1_000

  defp request(method, url, headers, nil) do
    opts = [timeout: request_timeout_ms(), connect_timeout: connect_timeout_ms()]
    req = {String.to_charlist(url), normalize_headers(headers)}

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} -> {:ok, status, resp_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, url, headers, payload) when is_map(payload) do
    body = Jason.encode!(payload)
    req_headers = [{"content-type", "application/json"} | headers] |> normalize_headers()
    opts = [timeout: request_timeout_ms(), connect_timeout: connect_timeout_ms()]
    req = {String.to_charlist(url), req_headers, ~c"application/json", body}

    case :httpc.request(method, req, opts, body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} -> {:ok, status, resp_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  defp normalize_headers(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp matrix_url, do: System.get_env("MATRIX_URL", "http://127.0.0.1:8008")
  defp matrix_domain, do: System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")
  defp matrix_agent_user, do: System.get_env("MATRIX_AGENT_USER", "automata")
  defp matrix_agent_password, do: System.get_env("MATRIX_AGENT_PASSWORD", "changeme123")
  defp sync_timeout_ms, do: System.get_env("MATRIX_SYNC_TIMEOUT_MS", "25000")

  defp request_timeout_ms,
    do: System.get_env("MATRIX_HTTP_TIMEOUT_MS", "30000") |> String.to_integer()

  defp connect_timeout_ms,
    do: System.get_env("MATRIX_HTTP_CONNECT_TIMEOUT_MS", "3000") |> String.to_integer()
end
