defmodule SentientwaveAutomata.Governance.LawProposal do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.{
    ConstitutionSnapshot,
    Law,
    LawVote,
    ProposalEligibleRole,
    ProposalElector
  }

  alias SentientwaveAutomata.Matrix.DirectoryUser

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @proposal_types [:create, :amend, :repeal]
  @statuses [:open, :approved, :rejected, :cancelled]
  @voting_scopes [:all_members, :role_subset]

  schema "governance_law_proposals" do
    field :reference, :string
    field :proposal_type, Ecto.Enum, values: @proposal_types
    field :status, Ecto.Enum, values: @statuses, default: :open
    field :proposed_slug, :string
    field :proposed_name, :string
    field :proposed_markdown_body, :string
    field :proposed_law_kind, Ecto.Enum, values: Law.law_kinds(), default: :general
    field :proposed_rule_config, :map, default: %{}
    field :reason, :string
    field :voting_scope, Ecto.Enum, values: @voting_scopes, default: :all_members
    field :voting_rule_snapshot, :map, default: %{}
    field :opened_at, :utc_datetime_usec
    field :closes_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    field :room_id, :string
    field :proposal_message_id, :string
    field :result_message_id, :string
    field :raw_event, :map, default: %{}
    field :workflow_id, :string
    field :metadata, :map, default: %{}

    belongs_to :law, Law
    belongs_to :created_by, DirectoryUser
    belongs_to :resolved_by, DirectoryUser

    has_many :votes, LawVote, foreign_key: :proposal_id
    has_many :eligible_role_links, ProposalEligibleRole, foreign_key: :proposal_id
    has_many :electors, ProposalElector, foreign_key: :proposal_id
    has_many :constitution_snapshots, ConstitutionSnapshot, foreign_key: :proposal_id

    timestamps(type: :utc_datetime_usec)
  end

  def proposal_types, do: @proposal_types
  def statuses, do: @statuses
  def voting_scopes, do: @voting_scopes

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :reference,
      :law_id,
      :proposal_type,
      :status,
      :proposed_slug,
      :proposed_name,
      :proposed_markdown_body,
      :proposed_law_kind,
      :proposed_rule_config,
      :reason,
      :voting_scope,
      :voting_rule_snapshot,
      :opened_at,
      :closes_at,
      :resolved_at,
      :room_id,
      :proposal_message_id,
      :result_message_id,
      :raw_event,
      :workflow_id,
      :metadata,
      :created_by_id,
      :resolved_by_id
    ])
    |> validate_required([
      :reference,
      :proposal_type,
      :status,
      :voting_scope,
      :voting_rule_snapshot,
      :opened_at,
      :closes_at,
      :created_by_id
    ])
    |> update_change(:reference, &normalize_text/1)
    |> update_change(:proposed_slug, &normalize_slug/1)
    |> update_change(:proposed_name, &normalize_text/1)
    |> update_change(:proposed_markdown_body, &normalize_body/1)
    |> update_change(:reason, &normalize_body/1)
    |> validate_length(:reference, min: 1, max: 64)
    |> unique_constraint(:reference)
    |> unique_constraint(:workflow_id)
    |> assoc_constraint(:law)
    |> assoc_constraint(:created_by)
    |> assoc_constraint(:resolved_by)
  end

  defp normalize_slug(nil), do: nil

  defp normalize_slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.replace(~r/^-+|-+$/u, "")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_text(nil), do: nil
  defp normalize_text(value), do: value |> to_string() |> String.trim()
  defp normalize_body(nil), do: nil
  defp normalize_body(value), do: value |> to_string() |> String.trim()
end
