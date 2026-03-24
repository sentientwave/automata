defmodule SentientwaveAutomata.Settings.LLMProviderConfig do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @providers ~w(local openai gemini anthropic cerebras openrouter lm-studio ollama)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "llm_provider_configs" do
    field :singleton_key, :string, default: "default"
    field :name, :string, default: "Primary"
    field :slug, :string, default: "primary"
    field :provider, :string, default: "local"
    field :model, :string, default: "local-default"
    field :base_url, :string
    field :api_token, :string
    field :enabled, :boolean, default: true
    field :is_default, :boolean, default: false
    field :timeout_seconds, :integer, default: 600
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :singleton_key,
      :name,
      :slug,
      :provider,
      :model,
      :base_url,
      :api_token,
      :enabled,
      :is_default,
      :timeout_seconds,
      :metadata
    ])
    |> put_default_singleton()
    |> put_default_name_and_slug()
    |> validate_required([:singleton_key, :name, :slug, :provider, :model])
    |> update_change(:slug, &normalize_slug/1)
    |> validate_inclusion(:provider, @providers)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:slug, min: 1, max: 120)
    |> validate_length(:model, min: 1, max: 200)
    |> validate_length(:base_url, max: 500)
    |> validate_length(:api_token, max: 4096)
    |> validate_number(:timeout_seconds, greater_than_or_equal_to: 1, less_than_or_equal_to: 3600)
    |> unique_constraint(:slug)
  end

  defp put_default_singleton(changeset) do
    case get_field(changeset, :singleton_key) do
      nil -> put_change(changeset, :singleton_key, "default")
      "" -> put_change(changeset, :singleton_key, "default")
      _ -> changeset
    end
  end

  defp put_default_name_and_slug(changeset) do
    name =
      case get_field(changeset, :name) do
        nil -> "Primary"
        "" -> "Primary"
        value -> value
      end

    slug =
      case get_field(changeset, :slug) do
        nil -> normalize_slug(name)
        "" -> normalize_slug(name)
        value -> normalize_slug(value)
      end

    changeset
    |> put_change(:name, name)
    |> put_change(:slug, slug)
  end

  defp normalize_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/^-+|-+$/u, "")
    |> case do
      "" -> "provider"
      slug -> slug
    end
  end
end
