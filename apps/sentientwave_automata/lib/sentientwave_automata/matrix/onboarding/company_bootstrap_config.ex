defmodule SentientwaveAutomata.Matrix.Onboarding.CompanyBootstrapConfig do
  @moduledoc """
  Normalized company bootstrap configuration for Matrix-first onboarding.
  """

  alias SentientwaveAutomata.Matrix.Onboarding.GroupBootstrapConfig

  @enforce_keys [:company_key, :company_name, :admin_user_id, :groups]
  defstruct [
    :company_key,
    :company_name,
    :admin_user_id,
    :homeserver,
    :default_group_key,
    groups: []
  ]

  @type t :: %__MODULE__{
          company_key: String.t(),
          company_name: String.t(),
          admin_user_id: String.t(),
          homeserver: String.t() | nil,
          default_group_key: String.t() | nil,
          groups: [GroupBootstrapConfig.t()]
        }

  @spec new(map(), map() | [map()] | nil) :: {:ok, t()} | {:error, atom()}
  def new(company_attrs, group_attrs \\ nil)

  def new(company_attrs, group_attrs) when is_map(company_attrs) do
    groups_param =
      case group_attrs do
        nil -> Map.get(company_attrs, "groups") || Map.get(company_attrs, :groups)
        value -> value
      end

    with {:ok, company_key} <- fetch_non_empty(company_attrs, ["key", :key]),
         {:ok, company_name} <- fetch_non_empty(company_attrs, ["name", :name]),
         {:ok, admin_user_id} <- fetch_non_empty(company_attrs, ["admin_user_id", :admin_user_id]),
         {:ok, groups} <- parse_groups(groups_param),
         {:ok, default_group_key} <- parse_default_group(company_attrs, groups) do
      {:ok,
       %__MODULE__{
         company_key: company_key,
         company_name: company_name,
         admin_user_id: admin_user_id,
         homeserver: optional_string(company_attrs, ["homeserver", :homeserver]),
         default_group_key: default_group_key,
         groups: groups
       }}
    end
  end

  def new(_, _), do: {:error, :invalid_company}

  defp parse_groups(groups) when is_list(groups) do
    groups
    |> Enum.reduce_while({:ok, []}, fn group_attrs, {:ok, acc} ->
      case GroupBootstrapConfig.new(group_attrs) do
        {:ok, group} -> {:cont, {:ok, [group | acc]}}
        {:error, _} -> {:halt, {:error, :invalid_group}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :invalid_group}
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      other -> other
    end
  end

  defp parse_groups(group) when is_map(group), do: parse_groups([group])
  defp parse_groups(_), do: {:error, :invalid_group}

  defp parse_default_group(company_attrs, groups) do
    requested_default = optional_string(company_attrs, ["default_group_key", :default_group_key])

    value =
      requested_default ||
        groups
        |> List.first()
        |> case do
          %GroupBootstrapConfig{key: key} -> key
          _ -> nil
        end

    if Enum.any?(groups, fn %GroupBootstrapConfig{key: key} -> key == value end) do
      {:ok, value}
    else
      {:error, :invalid_company}
    end
  end

  defp fetch_non_empty(attrs, keys) do
    value =
      keys
      |> Enum.find_value(fn key -> Map.get(attrs, key) end)
      |> case do
        value when is_binary(value) -> String.trim(value)
        _ -> nil
      end

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, :invalid_company}
    end
  end

  defp optional_string(attrs, keys) do
    value = Enum.find_value(keys, fn key -> Map.get(attrs, key) end)

    case value do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if trimmed == "", do: nil, else: trimmed

      _ ->
        nil
    end
  end
end
