defmodule SentientwaveAutomata.Adapters.Matrix.Synapse do
  @moduledoc """
  Matrix adapter backed by Synapse client APIs.
  """

  require Logger

  @behaviour SentientwaveAutomata.Adapters.Matrix.Behaviour

  alias SentientwaveAutomata.Agents.MentionDispatcher
  alias SentientwaveAutomata.Governance.Dispatcher, as: GovernanceDispatcher

  @token_key {:sentientwave_automata, :matrix_agent_token}
  @reader_token_key {:sentientwave_automata, :matrix_reader_token}
  @user_token_key {:sentientwave_automata, :matrix_user_tokens}

  @impl true
  def post_message(room_id, message, metadata) when is_binary(room_id) and room_id != "" do
    with {:ok, token, sender} <- agent_token() do
      case do_send_message(token, room_id, message, metadata_txn_id(metadata)) do
        {:ok, status, _body} when status in 200..299 ->
          Logger.info(
            "matrix_synapse_send room=#{room_id} sender=#{sender} meta=#{inspect(metadata)}"
          )

          :ok

        {:ok, 401, _body} ->
          with {:ok, fresh_token, _} <- force_refresh_token(),
               {:ok, status, _body} <- do_send_message(fresh_token, room_id, message, nil),
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

          case do_send_message(token, room_id, message, nil) do
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

  @doc """
  Posts a message to a Matrix room using a specific user's credentials.

  `credentials` is a map with `localpart` and `password` keys (as stored in an
  agent wallet's `matrix_credentials`). The access token is cached per
  localpart; on 401 the user is re-authenticated once and the send retried.
  """
  @spec post_message_as(String.t(), String.t(), map(), map()) :: :ok | {:error, term()}
  def post_message_as(room_id, message, credentials) do
    post_message_as(room_id, message, credentials, %{})
  end

  @impl true
  def post_message_as(room_id, message, credentials, metadata)
      when is_binary(room_id) and room_id != "" and is_binary(message) and is_map(credentials) do
    with {:ok, token, sender} <- user_token(credentials) do
      case do_send_message(token, room_id, message, nil) do
        {:ok, status, _body} when status in 200..299 ->
          Logger.info(
            "matrix_synapse_send_as room=#{room_id} sender=#{sender} meta=#{inspect(metadata)}"
          )

          :ok

        {:ok, 401, _body} ->
          with {:ok, fresh_token, fresh_sender} <- refresh_user_token(credentials),
               {:ok, status, _body} <- do_send_message(fresh_token, room_id, message, nil),
               true <- status in 200..299 do
            Logger.info(
              "matrix_synapse_send_as room=#{room_id} sender=#{fresh_sender} refresh=true meta=#{inspect(metadata)}"
            )

            :ok
          else
            false -> {:error, :send_unauthorized_after_refresh}
            {:ok, status, body} -> {:error, {:send_http_error, status, body}}
            {:error, reason} -> {:error, reason}
          end

        # The user cannot post until joined (M_FORBIDDEN): e.g. a new direct
        # message room, or a room where the agent was mentioned but has not
        # joined yet. Join with the same credentials, then retry once.
        {:ok, 403, body} ->
          case do_join_room_by_id(token, room_id) do
            {:ok, join_status, _join_body} when join_status in 200..299 ->
              Logger.info(
                "matrix_synapse_join_for_send room=#{room_id} sender=#{sender} meta=#{inspect(metadata)}"
              )

              case do_send_message(token, room_id, message, nil) do
                {:ok, status, _body} when status in 200..299 ->
                  :ok

                {:ok, status, retry_body} ->
                  {:error, {:send_http_error, status, retry_body}}

                {:error, reason} ->
                  {:error, reason}
              end

            _ ->
              # Not invited / join not allowed: keep the original 403 error.
              {:error, {:send_http_error, 403, body}}
          end

        {:ok, 429, body} ->
          retry_ms = retry_after_ms(body)
          Process.sleep(retry_ms)

          case do_send_message(token, room_id, message, nil) do
            {:ok, status, _body} when status in 200..299 ->
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

  def post_message_as(_room_id, _message, _credentials, _metadata),
    do: {:error, :invalid_post_message_as_payload}

  @doc """
  Sets the typing indicator in a room on behalf of a specific user.
  """
  @spec set_typing_as(String.t(), boolean(), non_neg_integer(), map(), map()) ::
          :ok | {:error, term()}
  def set_typing_as(room_id, typing, timeout_ms, credentials) do
    set_typing_as(room_id, typing, timeout_ms, credentials, %{})
  end

  @impl true
  def set_typing_as(room_id, typing, timeout_ms, credentials, metadata)
      when is_binary(room_id) and room_id != "" and is_map(credentials) do
    with {:ok, token, sender} <- user_token(credentials) do
      case do_set_typing(token, sender, room_id, typing, timeout_ms) do
        {:ok, status, _body} when status in 200..299 ->
          Logger.debug(
            "matrix_synapse_typing_as room=#{room_id} sender=#{sender} typing=#{typing} meta=#{inspect(metadata)}"
          )

          :ok

        {:ok, 401, _body} ->
          with {:ok, fresh_token, fresh_sender} <- refresh_user_token(credentials),
               {:ok, status, _body} <-
                 do_set_typing(fresh_token, fresh_sender, room_id, typing, timeout_ms),
               true <- status in 200..299 do
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

  def set_typing_as(_room_id, _typing, _timeout_ms, _credentials, _metadata),
    do: {:error, :invalid_set_typing_as_payload}

  @spec joined_members(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def joined_members(room_id) when is_binary(room_id) and room_id != "" do
    with {:ok, token, _sender} <- reader_token() do
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
          with {:ok, fresh_token, _sender} <- refresh_reader_token(),
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

  @doc """
  Fetches the current room member states (join / invite / knock) via the
  client v3 state endpoint. Useful for detecting a direct-message room even
  before an invited agent has joined.
  """
  @spec room_member_states(String.t()) :: {:ok, map()} | {:error, term()}
  def room_member_states(room_id) when is_binary(room_id) and room_id != "" do
    with {:ok, token, _sender} <- reader_token() do
      url =
        "#{matrix_url()}/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/state"

      case request(:get, url, auth_headers(token), nil) do
        {:ok, status, body} when status in 200..299 ->
          decode_member_states(body)

        {:ok, 401, _body} ->
          with {:ok, fresh_token, _sender} <- refresh_reader_token(),
               {:ok, status, body} <- request(:get, url, auth_headers(fresh_token), nil),
               true <- status in 200..299 do
            decode_member_states(body)
          else
            false -> {:error, :member_states_unauthorized_after_refresh}
            {:ok, status, body} -> {:error, {:member_states_http_error, status, body}}
            {:error, reason} -> {:error, reason}
            _ -> {:ok, %{}}
          end

        {:ok, status, body} ->
          {:error, {:member_states_http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def room_member_states(_room_id), do: {:error, :invalid_room_id}

  defp decode_member_states(body) do
    case Jason.decode(body) do
      {:ok, events} when is_list(events) ->
        states =
          Enum.reduce(events, %{}, fn event, acc ->
            if Map.get(event, "type") == "m.room.member" and
                 is_binary(Map.get(event, "state_key", "")) do
              membership =
                event |> Map.get("content", %{}) |> Map.get("membership", "")

              if membership in ["join", "invite", "knock"] do
                Map.put(acc, Map.fetch!(event, "state_key"), membership)
              else
                acc
              end
            else
              acc
            end
          end)

        {:ok, states}

      _ ->
        {:ok, %{}}
    end
  end

  @doc """
  Resolves (and creates when needed) the direct-message room between the
  credential holder and `target_localpart`. Keeps the Matrix `m.direct`
  account data up to date so each colleague pair reuses a single DM room.
  """
  @spec resolve_direct_room(map(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_direct_room(credentials, target_localpart)
      when is_map(credentials) and is_binary(target_localpart) do
    target =
      target_localpart
      |> String.trim()
      |> String.downcase()
      |> String.trim_leading("@")
      |> String.split(":", parts: 2)
      |> List.first()

    with {:ok, token, sender} <- user_token(credentials),
         {:ok, existing} <- direct_room_for(token, sender, target) do
      case existing do
        nil -> create_direct_room(token, sender, target)
        room_id -> {:ok, room_id}
      end
    end
  end

  def resolve_direct_room(_credentials, _target_localpart),
    do: {:error, :invalid_resolve_direct_room_payload}

  @doc """
  Creates a Matrix room under the credential holder's account with the given
  name, topic, and invited localparts. Returns the new room id.
  """
  @spec create_room(map(), map()) :: {:ok, String.t()} | {:error, term()}
  def create_room(credentials, attrs) when is_map(credentials) and is_map(attrs) do
    with {:ok, token, _sender} <- user_token(credentials) do
      payload = %{
        "name" => Map.get(attrs, "name", ""),
        "topic" => Map.get(attrs, "topic", ""),
        "preset" => "private_chat",
        "invite" => invite_mxids(Map.get(attrs, "invite", []))
      }

      case request(
             :post,
             "#{matrix_url()}/_matrix/client/v3/createRoom",
             auth_headers(token),
             payload
           ) do
        {:ok, status, body} when status in 200..299 ->
          case Jason.decode(body) do
            {:ok, %{"room_id" => room_id}} when is_binary(room_id) -> {:ok, room_id}
            _ -> {:error, :invalid_create_room_response}
          end

        {:ok, status, body} ->
          {:error, {:create_room_http_error, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def create_room(_credentials, _attrs), do: {:error, :invalid_create_room_payload}

  defp invite_mxids(localparts) when is_list(localparts) do
    localparts
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn lp ->
      lp = lp |> String.trim_leading("@") |> String.split(":", parts: 2) |> List.first()
      "@#{String.downcase(lp)}:#{matrix_domain()}"
    end)
  end

  defp direct_room_for(token, sender, target_localpart) do
    target_mxid = "@#{target_localpart}:#{matrix_domain()}"
    url = account_data_url(sender, "m.direct")

    with {:ok, status, body} <- request(:get, url, auth_headers(token), nil),
         true <- status in 200..299,
         {:ok, %{^target_mxid => rooms}} <- Jason.decode(body) do
      rooms
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.find_value({:ok, nil}, fn room_id ->
        if user_joined_room?(token, room_id), do: {:ok, room_id}, else: nil
      end)
    else
      _ -> {:ok, nil}
    end
  end

  # A stored m.direct room is only reusable when the credential holder is
  # still joined; otherwise the send would 403 and we should create a new DM.
  defp user_joined_room?(token, room_id) do
    url =
      "#{matrix_url()}/_matrix/client/v3/rooms/#{URI.encode_www_form(room_id)}/joined_members"

    case request(:get, url, auth_headers(token), nil) do
      {:ok, status, body} when status in 200..299 ->
        case Jason.decode(body) do
          {:ok, %{"joined" => joined}} when is_map(joined) -> map_size(joined) > 0
          _ -> false
        end

      _ ->
        false
    end
  end

  defp create_direct_room(token, sender, target_localpart) do
    target_mxid = "@#{target_localpart}:#{matrix_domain()}"

    payload = %{
      "preset" => "trusted_private_chat",
      "is_direct" => true,
      "invite" => [target_mxid]
    }

    url = "#{matrix_url()}/_matrix/client/v3/createRoom"

    with {:ok, status, body} <- request(:post, url, auth_headers(token), payload),
         true <- status in 200..299,
         {:ok, %{"room_id" => room_id}} when is_binary(room_id) <- Jason.decode(body),
         :ok <- store_direct_room(token, sender, target_mxid, room_id) do
      {:ok, room_id}
    else
      false -> {:error, :create_room_http_error}
      {:ok, %{"room_id" => _}} -> {:error, :invalid_create_room_response}
      {:ok, _} -> {:error, :invalid_create_room_response}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :create_room_failed}
    end
  end

  defp store_direct_room(token, sender, target_mxid, room_id) do
    url = account_data_url(sender, "m.direct")

    existing =
      case request(:get, url, auth_headers(token), nil) do
        {:ok, status, body} when status in 200..299 ->
          case Jason.decode(body) do
            {:ok, %{} = map} -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    merged =
      Map.update(existing, target_mxid, [room_id], fn rooms ->
        [room_id | Enum.reject(rooms, &(&1 == room_id))]
      end)

    case request(:put, url, auth_headers(token), merged) do
      {:ok, status, _body} when status in 200..299 -> :ok
      {:ok, _status, _body} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp account_data_url(user_mxid, event_type) do
    "#{matrix_url()}/_matrix/client/v3/user/#{URI.encode_www_form(user_mxid)}/account_data/#{event_type}"
  end

  @doc """
  The localpart of the room reader account (the account whose /sync is
  polled for incoming messages).
  """
  @spec reader_localpart() :: String.t()
  def reader_localpart, do: matrix_reader_user()

  @spec sync(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def sync(since \\ nil) do
    with {:ok, token, _sender} <- reader_token() do
      url = sync_url(since)

      case request(:get, url, auth_headers(token), nil) do
        {:ok, status, body} when status in 200..299 ->
          Jason.decode(body)

        {:ok, 401, _body} ->
          with {:ok, fresh_token, _sender} <- refresh_reader_token(),
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

  defp user_token(credentials) when is_map(credentials) do
    localpart = credentials |> Map.get("localpart") |> to_string() |> String.trim()
    password = credentials |> Map.get("password") |> to_string() |> String.trim()
    cached = cached_user_token(localpart)

    cond do
      localpart == "" or password == "" ->
        {:error, :missing_user_credentials}

      match?(%{token: token} when is_binary(token), cached) ->
        {:ok, cached.token, cached.sender}

      true ->
        refresh_user_token(credentials)
    end
  end

  defp user_token(_credentials), do: {:error, :invalid_credentials}

  defp refresh_user_token(credentials) do
    localpart = credentials |> Map.get("localpart") |> to_string() |> String.trim()
    password = credentials |> Map.get("password") |> to_string() |> String.trim()

    with true <- localpart != "" and password != "" do
      case login_user(localpart, password) do
        {:ok, token, sender} = ok ->
          cache_user_token(localpart, token, sender)
          ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :missing_user_credentials}
    end
  end

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

          {:ok, %{"access_token" => token}} ->
            {:ok, token, "@#{localpart}:#{matrix_domain()}"}

          _ ->
            {:error, :invalid_login_response}
        end

      {:ok, 401, _body} ->
        {:error, :user_login_unauthorized}

      {:ok, status, body} ->
        {:error, {:user_login_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cached_user_token(localpart) when is_binary(localpart) and localpart != "" do
    @user_token_key
    |> :persistent_term.get(%{})
    |> Map.get(localpart, nil)
  end

  defp cached_user_token(_), do: nil

  defp cache_user_token(localpart, token, sender) do
    cache = :persistent_term.get(@user_token_key, %{})

    :persistent_term.put(
      @user_token_key,
      Map.put(cache, localpart, %{token: token, sender: sender})
    )

    :ok
  end

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

  defp metadata_txn_id(metadata) when is_map(metadata), do: Map.get(metadata, "txn_id")
  defp metadata_txn_id(_), do: nil

  defp do_send_message(token, room_id, message, provided_txn_id) do
    # Matrix dedupes sends per (room_id, txn_id): when the caller supplies a
    # deterministic txn id (e.g. derived from a Temporal workflow id), activity
    # retries and 401/429 resends cannot post duplicates.
    txn_id =
      case provided_txn_id do
        id when is_binary(id) and id != "" -> "txn_" <> id
        _ -> "txn_" <> Integer.to_string(System.unique_integer([:positive]))
      end

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

  # Access token for the room *reader* account — the account whose /sync is
  # polled for incoming user messages. Defaults to the bot agent identity.
  defp reader_token do
    case :persistent_term.get(@reader_token_key, nil) do
      %{token: token, sender: sender} when is_binary(token) and is_binary(sender) ->
        {:ok, token, sender}

      _ ->
        refresh_reader_token()
    end
  end

  defp refresh_reader_token do
    case login_reader() do
      {:ok, token, sender} = ok ->
        :persistent_term.put(@reader_token_key, %{token: token, sender: sender})
        ok

      other ->
        other
    end
  end

  defp login_reader do
    payload = %{
      "type" => "m.login.password",
      "identifier" => %{"type" => "m.id.user", "user" => matrix_reader_user()},
      "password" => matrix_reader_password()
    }

    case request(:post, "#{matrix_url()}/_matrix/client/v3/login", [], payload) do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => token, "user_id" => user_id}} ->
            {:ok, token, user_id}

          {:ok, %{"access_token" => token}} ->
            {:ok, token, "@#{matrix_reader_user()}:#{matrix_domain()}"}

          _ ->
            {:error, :invalid_login_response}
        end

      {:ok, status, body} ->
        {:error, {:reader_login_failed, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
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
    case Req.request(
           method: method,
           url: url,
           headers: headers,
           receive_timeout: request_timeout_ms(),
           connect_options: [timeout: connect_timeout_ms()],
           decode_body: false,
           retry: false
         ) do
      {:ok, %{status: status, body: resp_body}} -> {:ok, status, resp_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(method, url, headers, payload) when is_map(payload) do
    case Req.request(
           method: method,
           url: url,
           headers: headers,
           json: payload,
           receive_timeout: request_timeout_ms(),
           connect_options: [timeout: connect_timeout_ms()],
           decode_body: false,
           retry: false
         ) do
      {:ok, %{status: status, body: resp_body}} -> {:ok, status, resp_body}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auth_headers(token), do: [{"authorization", "Bearer " <> token}]

  defp matrix_url, do: System.get_env("MATRIX_URL", "http://127.0.0.1:8008")
  defp matrix_domain, do: System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")
  defp matrix_agent_user, do: System.get_env("MATRIX_AGENT_USER", "automata")
  defp matrix_agent_password, do: System.get_env("MATRIX_AGENT_PASSWORD", "changeme123")

  defp matrix_reader_user, do: System.get_env("MATRIX_READER_USER", matrix_agent_user())

  defp matrix_reader_password,
    do: System.get_env("MATRIX_READER_PASSWORD", matrix_agent_password())

  defp sync_timeout_ms, do: System.get_env("MATRIX_SYNC_TIMEOUT_MS", "25000")

  defp request_timeout_ms,
    do: System.get_env("MATRIX_HTTP_TIMEOUT_MS", "30000") |> String.to_integer()

  defp connect_timeout_ms,
    do: System.get_env("MATRIX_HTTP_CONNECT_TIMEOUT_MS", "3000") |> String.to_integer()
end
