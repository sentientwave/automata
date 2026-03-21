defmodule SentientwaveAutomata.Governance.ProposalEligibleRole do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.{LawProposal, Role}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "governance_proposal_eligible_roles" do
    field :metadata, :map, default: %{}

    belongs_to :proposal, LawProposal
    belongs_to :role, Role

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:proposal_id, :role_id, :metadata])
    |> validate_required([:proposal_id, :role_id])
    |> assoc_constraint(:proposal)
    |> assoc_constraint(:role)
    |> unique_constraint([:proposal_id, :role_id])
  end
end
