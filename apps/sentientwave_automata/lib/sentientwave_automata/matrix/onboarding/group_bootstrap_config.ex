defmodule SentientwaveAutomata.Matrix.Onboarding.GroupBootstrapConfig do
  @moduledoc """
  Normalized configuration used to bootstrap a Matrix group for a company.
  """

  @enforce_keys [:key, :name]
  defstruct [:key, :name, :parent_key, :topic, visibility: :private, auto_join: false]

  @type visibility :: :private | :public

  @type t :: %__MODULE__{
          key: String.t(),
          name: String.t(),
          parent_key: String.t() | nil,
          topic: String.t() | nil,
          visibility: visibility(),
          auto_join: boolean()
        }

  @spec new(map()) :: {:ok, t()} | {:error, atom()}
  def new(attrs) when is_map(attrs) do
    with {:ok, key} <- fetch_non_empty(attrs, ["key", :key]),
         {:ok, name} <- fetch_non_empty(attrs, ["name", :name]),
         {:ok, visibility} <-
           parse_visibility(Map.get(attrs, "visibility") || Map.get(attrs, :visibility)),
         {:ok, auto_join} <-
           parse_auto_join(Map.get(attrs, "auto_join") || Map.get(attrs, :auto_join)) do
      {:ok,
       %__MODULE__{
         key: key,
         name: name,
         parent_key: optional_string(attrs, ["parent_key", :parent_key]),
         topic: optional_string(attrs, ["topic", :topic]),
         visibility: visibility,
         auto_join: auto_join
       }}
    end
  end

  def new(_), do: {:error, :invalid_group}

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
      {:error, :invalid_group}
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

  defp parse_visibility(nil), do: {:ok, :private}
  defp parse_visibility("private"), do: {:ok, :private}
  defp parse_visibility("public"), do: {:ok, :public}
  defp parse_visibility(:private), do: {:ok, :private}
  defp parse_visibility(:public), do: {:ok, :public}
  defp parse_visibility(_), do: {:error, :invalid_group}

  defp parse_auto_join(nil), do: {:ok, false}
  defp parse_auto_join(value) when is_boolean(value), do: {:ok, value}
  defp parse_auto_join(_), do: {:error, :invalid_group}
end
