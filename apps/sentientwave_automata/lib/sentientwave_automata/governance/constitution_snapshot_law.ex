defmodule SentientwaveAutomata.Governance.ConstitutionSnapshotLaw do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.{ConstitutionSnapshot, Law}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "governance_constitution_snapshot_laws" do
    field :position, :integer, default: 100
    field :metadata, :map, default: %{}

    belongs_to :snapshot, ConstitutionSnapshot
    belongs_to :law, Law

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:snapshot_id, :law_id, :position, :metadata])
    |> validate_required([:snapshot_id, :law_id, :position])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> assoc_constraint(:snapshot)
    |> assoc_constraint(:law)
    |> unique_constraint(:law_id,
      name: :governance_constitution_snapshot_laws_snapshot_id_law_id_index
    )
  end
end
