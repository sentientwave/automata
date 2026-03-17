defmodule SentientwaveAutomata.Matrix.Onboarding do
  @moduledoc """
  Matrix-first onboarding payload handling for company/group provisioning.

  This module validates minimal bootstrap inputs required by the all-in-one
  installer and produces a normalized config map consumed by scripts and APIs.
  """

  @max_invites 200
  alias SentientwaveAutomata.Matrix.Onboarding.ProvisioningPayload

  @type config :: %{
          company_name: String.t(),
          group_name: String.t(),
          homeserver_domain: String.t(),
          admin_user: String.t(),
          invitees: [String.t()],
          room_alias: String.t()
        }

  @spec validate_payload(map()) :: {:ok, map()} | {:error, map()}
  def validate_payload(attrs) when is_map(attrs) do
    if provisioning_payload?(attrs) do
      case ProvisioningPayload.validate(attrs) do
        {:ok, payload} ->
          {:ok, serialize_provisioning(payload)}

        {:error, reason} ->
          {:error, %{reason: Atom.to_string(reason)}}
      end
    else
      build_config(attrs)
    end
  end

  @spec build_config(map()) :: {:ok, config()} | {:error, map()}
  def build_config(attrs) when is_map(attrs) do
    company_name = clean(Map.get(attrs, :company_name) || Map.get(attrs, "company_name"))
    group_name = clean(Map.get(attrs, :group_name) || Map.get(attrs, "group_name"))

    homeserver_domain =
      clean(Map.get(attrs, :homeserver_domain) || Map.get(attrs, "homeserver_domain"))

    admin_user = clean(Map.get(attrs, :admin_user) || Map.get(attrs, "admin_user"))

    invitees =
      attrs
      |> extract_invites()
      |> Enum.map(&normalize_user_id(&1, homeserver_domain))
      |> Enum.uniq()

    errors = %{}
    errors = require(errors, :company_name, company_name)
    errors = require(errors, :group_name, group_name)
    errors = require(errors, :homeserver_domain, homeserver_domain)
    errors = require(errors, :admin_user, admin_user)
    errors = validate_invites(errors, invitees)

    if map_size(errors) == 0 do
      {:ok,
       %{
         company_name: company_name,
         group_name: group_name,
         homeserver_domain: homeserver_domain,
         admin_user: normalize_user_id(admin_user, homeserver_domain),
         invitees: invitees,
         room_alias: room_alias(company_name, group_name)
       }}
    else
      {:error, errors}
    end
  end

  @spec extract_invites(map()) :: [String.t()]
  def extract_invites(attrs) do
    case Map.get(attrs, :invitees) || Map.get(attrs, "invitees") || [] do
      list when is_list(list) ->
        Enum.map(list, &clean/1)

      csv when is_binary(csv) ->
        csv
        |> String.split([",", "\n"], trim: true)
        |> Enum.map(&clean/1)

      _ ->
        []
    end
    |> Enum.reject(&(&1 == ""))
  end

  defp validate_invites(errors, invites) do
    cond do
      length(invites) > @max_invites ->
        Map.put(errors, :invitees, "too many invitees (max #{@max_invites})")

      Enum.any?(invites, &invalid_localpart?/1) ->
        Map.put(errors, :invitees, "invitees must be valid Matrix IDs or localparts")

      true ->
        errors
    end
  end

  defp invalid_localpart?("@" <> rest), do: String.contains?(rest, " ") or rest == ""
  defp invalid_localpart?(value), do: String.contains?(value, " ") or value == ""

  defp require(errors, _key, value) when is_binary(value) and value != "", do: errors
  defp require(errors, key, _value), do: Map.put(errors, key, "is required")

  defp clean(nil), do: ""
  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value), do: value |> to_string() |> String.trim()

  defp normalize_user_id("@" <> _ = user_id, _domain), do: user_id
  defp normalize_user_id(localpart, domain), do: "@#{localpart}:#{domain}"

  defp provisioning_payload?(attrs) do
    is_map(Map.get(attrs, "company") || Map.get(attrs, :company)) and
      is_map(Map.get(attrs, "group") || Map.get(attrs, :group))
  end

  defp serialize_provisioning(%{company: company, group: group, invites: invites}) do
    %{
      company: %{
        key: company.company_key,
        name: company.company_name,
        admin_user_id: company.admin_user_id,
        homeserver: company.homeserver,
        default_group_key: company.default_group_key
      },
      group: %{
        key: group.key,
        name: group.name,
        parent_key: group.parent_key,
        topic: group.topic,
        visibility: Atom.to_string(group.visibility),
        auto_join: group.auto_join
      },
      invites: invites
    }
  end

  defp room_alias(company_name, group_name) do
    [company_name, group_name, "automata"]
    |> Enum.map(&String.downcase/1)
    |> Enum.map(&String.replace(&1, ~r/[^a-z0-9]+/u, "-"))
    |> Enum.map(&String.trim(&1, "-"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("-")
  end
end
