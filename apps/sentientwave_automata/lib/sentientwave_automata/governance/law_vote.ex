defmodule SentientwaveAutomata.Governance.LawVote do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.LawProposal
  alias SentientwaveAutomata.Matrix.DirectoryUser

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @choices [:approve, :reject, :abstain]

  schema "governance_law_votes" do
    field :choice, Ecto.Enum, values: @choices
    field :cast_at, :utc_datetime_usec
    field :room_id, :string
    field :message_id, :string
    field :raw_event, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :proposal, LawProposal
    belongs_to :voter, DirectoryUser

    timestamps(type: :utc_datetime_usec)
  end

  def choices, do: @choices

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [
      :proposal_id,
      :voter_id,
      :choice,
      :cast_at,
      :room_id,
      :message_id,
      :raw_event,
      :metadata
    ])
    |> validate_required([:proposal_id, :voter_id, :choice, :cast_at])
    |> assoc_constraint(:proposal)
    |> assoc_constraint(:voter)
    |> unique_constraint(:voter_id, name: :governance_law_votes_proposal_id_voter_id_index)
  end
end
