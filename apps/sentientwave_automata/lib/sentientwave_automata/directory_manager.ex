defmodule SentientwaveAutomata.DirectoryManager do
  @moduledoc """
  Coordinates directory persistence with Matrix reconciliation and agent runtime state.
  """

  alias SentientwaveAutomata.Agents
  alias SentientwaveAutomata.Matrix.Directory
  alias SentientwaveAutomata.Matrix.SynapseAdmin
  alias SentientwaveAutomata.Security.Passwords

  @type result :: %{
          user: Directory.user(),
          generated_password: String.t() | nil,
          warnings: [String.t()]
        }

  @spec create_user(map()) :: {:ok, result()} | {:error, term()}
  def create_user(attrs) when is_map(attrs) do
    password = generated_password()
    kind = normalize_kind(fetch_attr(attrs, :kind, "person"))

    payload =
      attrs
      |> base_directory_attrs(kind)
      |> Map.put(:password, password)
      |> put_metadata_markers(true)

    with {:ok, user} <- Directory.upsert_user(payload) do
      warnings = []
      warnings = maybe_sync_runtime(nil, user, warnings)
      warnings = maybe_reconcile_user(user, warnings, force_password: true)
      {:ok, %{user: user, generated_password: password, warnings: warnings}}
    end
  end

  @spec update_user(String.t(), map()) :: {:ok, result()} | {:error, term()}
  def update_user(existing_localpart, attrs)
      when is_binary(existing_localpart) and is_map(attrs) do
    case Directory.get_user(existing_localpart) do
      nil ->
        {:error, :not_found}

      previous_user ->
        kind = normalize_kind(fetch_attr(attrs, :kind, previous_user.kind))

        target_localpart =
          attrs
          |> fetch_attr(:localpart, previous_user.localpart)
          |> normalize_localpart()

        payload =
          attrs
          |> base_directory_attrs(kind)
          |> Map.put(:localpart, target_localpart)
          |> Map.put(:password, previous_user.password)
          |> Map.put(
            :metadata,
            merge_metadata(previous_user.metadata, fetch_attr(attrs, :metadata, %{}))
          )
          |> put_metadata_markers(false)

        with {:ok, updated_user} <- Directory.upsert_user(payload) do
          warnings = []
          warnings = maybe_remove_old_directory_user(previous_user, updated_user, warnings)
          warnings = maybe_sync_runtime(previous_user, updated_user, warnings)
          warnings = maybe_reconcile_user(updated_user, warnings, [])
          warnings = maybe_deactivate_matrix_user(previous_user, updated_user, warnings)
          {:ok, %{user: updated_user, generated_password: nil, warnings: warnings}}
        end
    end
  end

  @spec rotate_password(String.t()) :: {:ok, result()} | {:error, term()}
  def rotate_password(localpart) when is_binary(localpart) do
    case Directory.get_user(localpart) do
      nil ->
        {:error, :not_found}

      user ->
        password = generated_password()

        payload =
          user
          |> Map.put(:password, password)
          |> put_metadata_markers(true)

        with {:ok, updated_user} <- Directory.upsert_user(payload) do
          warnings = []
          warnings = maybe_sync_runtime(user, updated_user, warnings)
          warnings = maybe_reconcile_user(updated_user, warnings, force_password: true)
          {:ok, %{user: updated_user, generated_password: password, warnings: warnings}}
        end
    end
  end

  @spec deactivate_user(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def deactivate_user(localpart) when is_binary(localpart) do
    case Directory.get_user(localpart) do
      nil ->
        {:error, :not_found}

      user ->
        :ok = Directory.delete_user(localpart)
        warnings = []
        warnings = maybe_disable_agent_runtime(user, warnings)
        warnings = maybe_deactivate_matrix_user(user.localpart, warnings)
        {:ok, warnings}
    end
  end

  @spec operational_status(Directory.user()) :: :online | :offline
  def operational_status(%{kind: kind} = user) when kind in [:agent, "agent"] do
    case Agents.get_agent_by_localpart(user.localpart) do
      %{status: :active, id: agent_id} ->
        case Agents.get_agent_wallet(agent_id) do
          %{status: "active", matrix_credentials: credentials} ->
            if matrix_credentials_present?(credentials) do
              :online
            else
              :offline
            end

          _ ->
            :offline
        end

      _ ->
        :offline
    end
  end

  def operational_status(_user), do: :offline

  defp maybe_sync_runtime(previous_user, user, warnings) do
    warnings =
      if previous_user && previous_user.kind == :agent && user.kind != :agent do
        maybe_disable_agent_runtime(previous_user, warnings)
      else
        warnings
      end

    if user.kind == :agent do
      case ensure_agent_runtime(previous_user, user) do
        :ok -> warnings
        {:warning, warning} -> [warning | warnings]
      end
    else
      warnings
    end
  end

  defp ensure_agent_runtime(previous_user, user) do
    existing_profile =
      previous_user
      |> existing_profile_candidates(user)
      |> Enum.find_value(& &1)

    slug =
      case existing_profile do
        %{slug: slug} when is_binary(slug) and slug != "" -> slug
        _ -> user.localpart
      end

    display_name = user.display_name || "Agent #{user.localpart}"

    with {:ok, profile} <-
           Agents.upsert_agent(%{
             slug: slug,
             kind: :agent,
             display_name: display_name,
             matrix_localpart: user.localpart,
             status: :active,
             metadata:
               merge_metadata(profile_metadata(existing_profile), %{
                 "source" => "directory_manager"
               })
           }),
         {:ok, _wallet} <- upsert_wallet(profile.id, user, existing_profile) do
      :ok
    else
      {:error, reason} ->
        {:warning, "Could not sync agent runtime: #{inspect(reason)}"}
    end
  end

  defp upsert_wallet(agent_id, user, existing_profile) do
    existing_wallet =
      case existing_profile do
        %{id: profile_id} -> Agents.get_agent_wallet(profile_id)
        _ -> Agents.get_agent_wallet(agent_id)
      end

    wallet_ref =
      case existing_wallet do
        %{wallet_ref: wallet_ref} when is_binary(wallet_ref) and wallet_ref != "" -> wallet_ref
        _ -> nil
      end

    metadata =
      existing_wallet
      |> wallet_metadata()
      |> merge_metadata(%{
        "source" => "directory_manager",
        "password_managed_by" => "automata"
      })

    attrs = %{
      kind: (existing_wallet && existing_wallet.kind) || "personal",
      status: "active",
      balance: (existing_wallet && existing_wallet.balance) || 0,
      matrix_credentials: %{
        localpart: user.localpart,
        mxid: mxid_for(user.localpart),
        password: user.password,
        homeserver_url: System.get_env("MATRIX_URL", "http://localhost:8008")
      },
      metadata: metadata
    }

    attrs =
      if wallet_ref do
        Map.put(attrs, :wallet_ref, wallet_ref)
      else
        attrs
      end

    Agents.upsert_agent_wallet(agent_id, attrs)
  end

  defp maybe_disable_agent_runtime(%{kind: :agent, localpart: localpart}, warnings) do
    localpart
    |> disable_agent_runtime()
    |> case do
      :ok -> warnings
      {:warning, warning} -> [warning | warnings]
    end
  end

  defp maybe_disable_agent_runtime(%{kind: "agent", localpart: localpart}, warnings) do
    maybe_disable_agent_runtime(%{kind: :agent, localpart: localpart}, warnings)
  end

  defp maybe_disable_agent_runtime(_user, warnings), do: warnings

  defp disable_agent_runtime(localpart) do
    case Agents.get_agent_by_localpart(localpart) do
      nil ->
        :ok

      profile ->
        _ =
          Agents.upsert_agent(%{
            slug: profile.slug,
            kind: profile.kind,
            display_name: profile.display_name,
            matrix_localpart: profile.matrix_localpart,
            status: :disabled,
            metadata:
              merge_metadata(profile.metadata, %{
                "deactivated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
              })
          })

        _ = maybe_disable_wallet(profile.id)
        :ok
    end
  rescue
    error ->
      {:warning, "Could not disable agent runtime for #{localpart}: #{Exception.message(error)}"}
  end

  defp maybe_disable_wallet(agent_id) do
    case Agents.get_agent_wallet(agent_id) do
      nil ->
        :ok

      wallet ->
        Agents.upsert_agent_wallet(agent_id, %{
          wallet_ref: wallet.wallet_ref,
          kind: wallet.kind,
          status: "disabled",
          balance: wallet.balance,
          matrix_credentials: wallet.matrix_credentials,
          metadata:
            merge_metadata(wallet.metadata, %{
              "deactivated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            })
        })

        :ok
    end
  end

  defp maybe_reconcile_user(user, warnings, opts) do
    case SynapseAdmin.reconcile_user(user, opts) do
      :ok -> warnings
      {:error, reason} -> ["Matrix reconciliation failed: #{inspect(reason)}" | warnings]
    end
  end

  defp maybe_deactivate_matrix_user(previous_user, user, warnings) do
    if previous_user && previous_user.localpart != user.localpart do
      maybe_deactivate_matrix_user(previous_user.localpart, warnings)
    else
      warnings
    end
  end

  defp maybe_deactivate_matrix_user(localpart, warnings) do
    case SynapseAdmin.deactivate_user(localpart) do
      :ok ->
        warnings

      {:error, reason} ->
        ["Could not deactivate previous Matrix account: #{inspect(reason)}" | warnings]
    end
  end

  defp maybe_remove_old_directory_user(previous_user, updated_user, warnings) do
    if previous_user.localpart != updated_user.localpart do
      :ok = Directory.delete_user(previous_user.localpart)
      warnings
    else
      warnings
    end
  end

  defp base_directory_attrs(attrs, kind) do
    %{
      localpart: attrs |> fetch_attr(:localpart) |> normalize_localpart(),
      kind: kind,
      display_name: attrs |> fetch_attr(:display_name) |> normalize_display_name(kind),
      admin: if(kind == :agent, do: false, else: attrs |> fetch_attr(:admin, false) |> truthy?()),
      metadata: normalize_metadata(fetch_attr(attrs, :metadata, %{}))
    }
  end

  defp put_metadata_markers(attrs, password_changed?) do
    metadata =
      attrs
      |> Map.get(:metadata, %{})
      |> Map.put("password_strategy", "generated")

    metadata =
      if password_changed? do
        Map.put(metadata, "last_password_rotated_at", DateTime.utc_now() |> DateTime.to_iso8601())
      else
        metadata
      end

    Map.put(attrs, :metadata, metadata)
  end

  defp merge_metadata(left, right) when is_map(left) and is_map(right), do: Map.merge(left, right)
  defp merge_metadata(left, _right) when is_map(left), do: left
  defp merge_metadata(_left, right) when is_map(right), do: right
  defp merge_metadata(_left, _right), do: %{}

  defp profile_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp profile_metadata(_), do: %{}

  defp wallet_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp wallet_metadata(_), do: %{}

  defp existing_profile_candidates(previous_user, user) do
    [
      previous_user && Agents.get_agent_by_localpart(previous_user.localpart),
      Agents.get_agent_by_localpart(user.localpart)
    ]
  end

  defp matrix_credentials_present?(credentials) when is_map(credentials) do
    localpart = Map.get(credentials, "localpart", Map.get(credentials, :localpart))
    mxid = Map.get(credentials, "mxid", Map.get(credentials, :mxid))
    password = Map.get(credentials, "password", Map.get(credentials, :password))

    Enum.all?([localpart, mxid, password], fn
      value when is_binary(value) -> String.trim(value) != ""
      _ -> false
    end)
  end

  defp matrix_credentials_present?(_), do: false

  defp generated_password do
    Passwords.generate(password_length())
  end

  defp password_length do
    System.get_env("AUTOMATA_GENERATED_PASSWORD_LENGTH", "20")
    |> String.to_integer()
  rescue
    _ -> 20
  end

  defp mxid_for(localpart) do
    "@#{localpart}:#{System.get_env("MATRIX_HOMESERVER_DOMAIN", "localhost")}"
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

  defp normalize_display_name(value, kind) do
    case value |> to_string() |> String.trim() do
      "" ->
        case kind do
          :agent -> ""
          :service -> ""
          _ -> ""
        end

      trimmed ->
        trimmed
    end
  end

  defp normalize_kind(value) when value in [:person, "person", :human, "human"], do: :person
  defp normalize_kind(value) when value in [:agent, "agent"], do: :agent
  defp normalize_kind(value) when value in [:service, "service"], do: :service
  defp normalize_kind(_), do: :person

  defp normalize_metadata(value) when is_map(value), do: value
  defp normalize_metadata(_), do: %{}

  defp fetch_attr(attrs, key, default \\ "") do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp truthy?(value), do: value in [true, "true", "1", 1, "on"]
end
