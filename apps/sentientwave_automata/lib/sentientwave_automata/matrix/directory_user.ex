defmodule SentientwaveAutomata.Matrix.DirectoryUser do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds [:person, :agent, :service]

  @type t :: %__MODULE__{
          id: binary() | nil,
          localpart: String.t() | nil,
          kind: :person | :agent | :service,
          display_name: String.t() | nil,
          password: String.t() | nil,
          admin: boolean(),
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "directory_users" do
    field :localpart, :string
    field :kind, Ecto.Enum, values: @kinds, default: :person
    field :display_name, :string
    field :password, :string
    field :admin, :boolean, default: false
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds

  def changeset(user, attrs, opts \\ []) do
    min_password_length = Keyword.get(opts, :min_password_length, 12)

    user
    |> cast(attrs, [:localpart, :kind, :display_name, :password, :admin, :metadata])
    |> validate_required([:localpart, :kind, :password])
    |> update_change(:localpart, &normalize_localpart/1)
    |> update_change(:display_name, &normalize_display_name/1)
    |> update_change(:password, &normalize_password/1)
    |> put_display_name_default()
    |> constrain_admin_by_kind()
    |> validate_length(:localpart, min: 1, max: 255)
    |> validate_length(:password, min: min_password_length)
    |> validate_format(:localpart, ~r/^[a-z0-9._-]+$/)
    |> unique_constraint(:localpart)
  end

  def seed_changeset(user, attrs) do
    user
    |> cast(attrs, [:localpart, :kind, :display_name, :password, :admin, :metadata])
    |> validate_required([:localpart, :kind, :password])
    |> update_change(:localpart, &normalize_localpart/1)
    |> update_change(:display_name, &normalize_display_name/1)
    |> update_change(:password, &normalize_password/1)
    |> put_display_name_default()
    |> constrain_admin_by_kind()
    |> validate_length(:localpart, min: 1, max: 255)
    |> validate_format(:localpart, ~r/^[a-z0-9._-]+$/)
    |> unique_constraint(:localpart)
  end

  defp put_display_name_default(changeset) do
    case get_field(changeset, :display_name) do
      value when is_binary(value) ->
        if String.trim(value) != "" do
          changeset
        else
          put_change(changeset, :display_name, default_display_name(changeset))
        end

      _ ->
        put_change(changeset, :display_name, default_display_name(changeset))
    end
  end

  defp default_display_name(changeset) do
    localpart = get_field(changeset, :localpart) || ""

    case get_field(changeset, :kind) do
      :agent -> "Agent #{localpart}"
      :service -> "Service #{localpart}"
      _ -> localpart
    end
  end

  defp constrain_admin_by_kind(changeset) do
    case get_field(changeset, :kind) do
      :agent -> put_change(changeset, :admin, false)
      _ -> changeset
    end
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

  defp normalize_display_name(value), do: value |> to_string() |> String.trim()
  defp normalize_password(value), do: value |> to_string() |> String.trim()
end
