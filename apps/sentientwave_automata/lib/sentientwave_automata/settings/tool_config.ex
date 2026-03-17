defmodule SentientwaveAutomata.Settings.ToolConfig do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @tools ~w(brave_search system_directory_admin run_shell)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tool_configs" do
    field :name, :string, default: "Brave Search"
    field :slug, :string, default: "brave-search"
    field :tool_name, :string, default: "brave_search"
    field :base_url, :string
    field :api_token, :string
    field :enabled, :boolean, default: true
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:name, :slug, :tool_name, :base_url, :api_token, :enabled, :metadata])
    |> put_default_name_and_slug()
    |> validate_required([:name, :slug, :tool_name])
    |> update_change(:slug, &normalize_slug/1)
    |> validate_inclusion(:tool_name, @tools)
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:slug, min: 1, max: 120)
    |> validate_length(:base_url, max: 500)
    |> validate_length(:api_token, max: 4096)
    |> unique_constraint(:slug)
  end

  defp put_default_name_and_slug(changeset) do
    name =
      case get_field(changeset, :name) do
        nil -> "Brave Search"
        "" -> "Brave Search"
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
      "" -> "tool"
      slug -> slug
    end
  end
end
