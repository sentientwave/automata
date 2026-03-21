defmodule SentientwaveAutomata.Governance.Role do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.{LawProposal, ProposalEligibleRole, RoleAssignment}
  alias SentientwaveAutomata.Matrix.DirectoryUser

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "governance_roles" do
    field :slug, :string
    field :name, :string
    field :description, :string
    field :enabled, :boolean, default: true
    field :metadata, :map, default: %{}

    has_many :assignments, RoleAssignment
    has_many :eligible_role_links, ProposalEligibleRole

    many_to_many :users, DirectoryUser,
      join_through: RoleAssignment,
      join_keys: [role_id: :id, user_id: :id]

    many_to_many :eligible_proposals, LawProposal,
      join_through: ProposalEligibleRole,
      join_keys: [role_id: :id, proposal_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(role, attrs) do
    role
    |> cast(attrs, [:slug, :name, :description, :enabled, :metadata])
    |> validate_required([:slug, :name])
    |> update_change(:slug, &normalize_slug/1)
    |> update_change(:name, &normalize_text/1)
    |> update_change(:description, &normalize_text/1)
    |> validate_length(:slug, min: 1, max: 120)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> unique_constraint(:slug)
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
end
