defmodule SentientwaveAutomata.Governance.ConstitutionSnapshot do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.{ConstitutionSnapshotLaw, Law, LawProposal}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "governance_constitution_snapshots" do
    field :version, :integer
    field :prompt_text, :string
    field :published_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :proposal, LawProposal
    has_many :law_memberships, ConstitutionSnapshotLaw, foreign_key: :snapshot_id

    many_to_many :laws, Law,
      join_through: ConstitutionSnapshotLaw,
      join_keys: [snapshot_id: :id, law_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:version, :prompt_text, :published_at, :proposal_id, :metadata])
    |> validate_required([:version, :prompt_text, :published_at])
    |> validate_number(:version, greater_than: 0)
    |> unique_constraint(:version)
    |> assoc_constraint(:proposal)
  end
end
