defmodule SentientwaveAutomata.Governance.ProposalElector do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.LawProposal
  alias SentientwaveAutomata.Matrix.DirectoryUser

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "governance_proposal_electors" do
    field :eligibility_scope, :string, default: "all_members"
    field :metadata, :map, default: %{}

    belongs_to :proposal, LawProposal
    belongs_to :user, DirectoryUser

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(elector, attrs) do
    elector
    |> cast(attrs, [:proposal_id, :user_id, :eligibility_scope, :metadata])
    |> validate_required([:proposal_id, :user_id, :eligibility_scope])
    |> assoc_constraint(:proposal)
    |> assoc_constraint(:user)
    |> unique_constraint(:user_id, name: :governance_proposal_electors_proposal_id_user_id_index)
  end
end
