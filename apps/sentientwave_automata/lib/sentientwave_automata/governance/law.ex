defmodule SentientwaveAutomata.Governance.Law do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.{
    ConstitutionSnapshot,
    ConstitutionSnapshotLaw,
    LawProposal
  }

  alias SentientwaveAutomata.Matrix.DirectoryUser

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:active, :repealed]
  @law_kinds [:general, :voting_policy]

  schema "governance_laws" do
    field :slug, :string
    field :name, :string
    field :markdown_body, :string
    field :law_kind, Ecto.Enum, values: @law_kinds, default: :general
    field :rule_config, :map, default: %{}
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :position, :integer, default: 100
    field :version, :integer, default: 1
    field :ratified_at, :utc_datetime_usec
    field :repealed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :created_by, DirectoryUser
    belongs_to :updated_by, DirectoryUser

    has_many :proposals, LawProposal
    has_many :snapshot_memberships, ConstitutionSnapshotLaw

    many_to_many :constitution_snapshots, ConstitutionSnapshot,
      join_through: ConstitutionSnapshotLaw,
      join_keys: [law_id: :id, snapshot_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def law_kinds, do: @law_kinds

  def changeset(law, attrs) do
    law
    |> cast(attrs, [
      :slug,
      :name,
      :markdown_body,
      :law_kind,
      :rule_config,
      :status,
      :position,
      :version,
      :ratified_at,
      :repealed_at,
      :metadata,
      :created_by_id,
      :updated_by_id
    ])
    |> validate_required([:slug, :name, :markdown_body, :law_kind, :status, :position, :version])
    |> update_change(:slug, &normalize_slug/1)
    |> update_change(:name, &normalize_text/1)
    |> update_change(:markdown_body, &normalize_body/1)
    |> put_default_name()
    |> validate_length(:slug, min: 1, max: 120)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:version, greater_than: 0)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> unique_constraint(:slug, name: :governance_laws_slug_index)
    |> assoc_constraint(:created_by)
    |> assoc_constraint(:updated_by)
  end

  defp put_default_name(changeset) do
    case get_field(changeset, :name) do
      value when is_binary(value) and value != "" -> changeset
      _ -> put_change(changeset, :name, get_field(changeset, :slug) || "Law")
    end
  end

  defp normalize_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/^-+|-+$/u, "")
  end

  defp normalize_text(value), do: value |> to_string() |> String.trim()
  defp normalize_body(value), do: value |> to_string() |> String.trim()
end
