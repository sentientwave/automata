defmodule SentientwaveAutomata.Matrix.Directory do
  @moduledoc """
  Persistent internal directory of human, agent, and service identities.
  """

  import Ecto.Query, warn: false

  alias SentientwaveAutomata.Matrix.DirectoryUser
  alias SentientwaveAutomata.Repo

  @type user :: %{
          id: String.t(),
          localpart: String.t(),
          kind: :person | :agent | :service,
          display_name: String.t(),
          password: String.t(),
          admin: boolean(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @spec list_users(keyword()) :: [user()]
  def list_users(opts \\ []) do
    DirectoryUser
    |> maybe_filter_kind(opts)
    |> maybe_search(opts)
    |> order_by([u], asc: u.localpart)
    |> Repo.all()
    |> Enum.map(&to_public_user/1)
  end

  @spec count_users(keyword()) :: non_neg_integer()
  def count_users(opts \\ []) do
    DirectoryUser
    |> maybe_filter_kind(opts)
    |> maybe_search(opts)
    |> Repo.aggregate(:count, :id)
  end

  @spec get_user(String.t()) :: user() | nil
  def get_user(localpart) do
    case get_user_record(localpart) do
      nil -> nil
      user -> to_public_user(user)
    end
  end

  @spec get_user_record(String.t()) :: DirectoryUser.t() | nil
  def get_user_record(localpart) do
    Repo.get_by(DirectoryUser, localpart: normalize_localpart(localpart))
  end

  @spec upsert_user(map(), keyword()) :: {:ok, user()} | {:error, map()}
  def upsert_user(attrs, opts \\ []) when is_map(attrs) do
    localpart = attrs |> fetch_attr(:localpart) |> normalize_localpart()
    changeset_opts = [min_password_length: Keyword.get(opts, :min_password_length, 12)]

    user_record =
      case localpart do
        "" -> %DirectoryUser{}
        value -> Repo.get_by(DirectoryUser, localpart: value) || %DirectoryUser{}
      end

    changeset =
      if Keyword.get(opts, :seed, false) do
        DirectoryUser.seed_changeset(user_record, normalize_user_attrs(attrs))
      else
        DirectoryUser.changeset(user_record, normalize_user_attrs(attrs), changeset_opts)
      end

    case Repo.insert_or_update(changeset) do
      {:ok, user} -> {:ok, to_public_user(user)}
      {:error, changeset} -> {:error, translate_errors(changeset)}
    end
  end

  @spec delete_user(String.t()) :: :ok
  def delete_user(localpart) do
    case get_user_record(localpart) do
      nil ->
        :ok

      %DirectoryUser{} = user ->
        _ = Repo.delete(user)
        :ok
    end
  end

  @doc """
  Seeds environment-configured directory users into the database.

  Seeded rows keep any env-provided passwords as-is so existing local installs
  continue to boot even when old env vars use shorter values.
  """
  @spec seed_from_env() :: :ok
  def seed_from_env do
    seed_users_from_env()
    |> Enum.each(fn attrs ->
      _ = upsert_user(attrs, seed: true)
    end)

    :ok
  end

  @spec kinds() :: [atom()]
  def kinds, do: DirectoryUser.kinds()

  defp seed_users_from_env do
    admin_localpart = System.get_env("MATRIX_ADMIN_USER", "admin")
    admin_password = fallback_seed_password(System.get_env("MATRIX_ADMIN_PASSWORD", ""))

    invite_password =
      fallback_seed_password(System.get_env("MATRIX_INVITE_PASSWORD", admin_password))

    invite_users = split_env_users("MATRIX_INVITE_USERS")
    agent_users = split_env_users("AUTOMATA_AGENT_USERS", "automata")

    agent_password =
      fallback_seed_password(System.get_env("AUTOMATA_AGENT_PASSWORD", invite_password))

    [
      %{
        localpart: admin_localpart,
        kind: :person,
        display_name: "Admin #{normalize_localpart(admin_localpart)}",
        password: admin_password,
        admin: true,
        metadata: %{"source" => "env_seed"}
      }
      | Enum.map(invite_users, fn user ->
          %{
            localpart: user,
            kind: :person,
            display_name: normalize_localpart(user),
            password: invite_password,
            admin: false,
            metadata: %{"source" => "env_seed"}
          }
        end)
    ] ++
      Enum.map(agent_users, fn user ->
        %{
          localpart: user,
          kind: :agent,
          display_name: "Agent #{normalize_localpart(user)}",
          password: agent_password,
          admin: false,
          metadata: %{"source" => "env_seed"}
        }
      end)
  end

  defp maybe_filter_kind(query, opts) do
    case Keyword.get(opts, :kind) do
      nil -> query
      "" -> query
      kind -> where(query, [u], u.kind == ^normalize_kind(kind))
    end
  end

  defp maybe_search(query, opts) do
    case Keyword.get(opts, :q) do
      nil ->
        query

      value ->
        trimmed = String.trim(to_string(value))

        if trimmed == "" do
          query
        else
          like = "%" <> trimmed <> "%"

          where(
            query,
            [u],
            ilike(u.localpart, ^like) or
              ilike(fragment("coalesce(?, '')", u.display_name), ^like)
          )
        end
    end
  end

  defp normalize_user_attrs(attrs) do
    localpart = attrs |> fetch_attr(:localpart) |> normalize_localpart()
    kind = attrs |> fetch_attr(:kind) |> normalize_kind()
    display_name = attrs |> fetch_attr(:display_name) |> normalize_display_name(localpart, kind)
    password = attrs |> fetch_attr(:password) |> to_string() |> String.trim()
    admin = attrs |> fetch_attr(:admin, false) |> truthy?()
    metadata = attrs |> fetch_attr(:metadata, %{}) |> normalize_metadata()

    %{
      localpart: localpart,
      kind: kind,
      display_name: display_name,
      password: password,
      admin: admin,
      metadata: metadata
    }
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
    |> Enum.into(%{}, fn {field, [message | _]} -> {field, message} end)
  end

  defp to_public_user(%DirectoryUser{} = user) do
    %{
      id: "#{user.kind}:#{user.localpart}",
      localpart: user.localpart,
      kind: user.kind,
      display_name: user.display_name || user.localpart,
      password: user.password,
      admin: user.admin,
      metadata: user.metadata || %{},
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end

  defp split_env_users(key, default_value \\ "") do
    key
    |> System.get_env(default_value)
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp fetch_attr(attrs, key, default \\ "") do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp normalize_localpart(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("@")
    |> String.split(":", parts: 2)
    |> List.first()
  end

  defp normalize_display_name(value, localpart, kind) do
    case value |> to_string() |> String.trim() do
      "" ->
        case kind do
          :agent -> "Agent #{localpart}"
          :service -> "Service #{localpart}"
          _ -> localpart
        end

      trimmed ->
        trimmed
    end
  end

  defp normalize_metadata(value) when is_map(value), do: value
  defp normalize_metadata(_), do: %{}

  defp normalize_kind(value) when value in [:person, "person", "human", :human], do: :person
  defp normalize_kind(value) when value in [:agent, "agent"], do: :agent
  defp normalize_kind(value) when value in [:service, "service"], do: :service
  defp normalize_kind(_), do: :person

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]

  defp fallback_seed_password(value) when is_binary(value) do
    case String.trim(value) do
      "" -> System.get_env("AUTOMATA_SEED_FALLBACK_PASSWORD", "changeme123!")
      trimmed -> trimmed
    end
  end

  defp fallback_seed_password(_),
    do: System.get_env("AUTOMATA_SEED_FALLBACK_PASSWORD", "changeme123!")
end
