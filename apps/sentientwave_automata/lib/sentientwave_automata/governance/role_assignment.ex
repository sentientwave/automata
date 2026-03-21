defmodule SentientwaveAutomata.Governance.RoleAssignment do
  use Ecto.Schema
  import Ecto.Changeset

  alias SentientwaveAutomata.Governance.Role
  alias SentientwaveAutomata.Matrix.DirectoryUser

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:active, :revoked]

  schema "governance_role_assignments" do
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :assigned_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :role, Role
    belongs_to :user, DirectoryUser

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:role_id, :user_id, :status, :assigned_at, :revoked_at, :metadata])
    |> validate_required([:role_id, :user_id, :status, :assigned_at])
    |> assoc_constraint(:role)
    |> assoc_constraint(:user)
    |> unique_constraint(:user_id, name: :governance_role_assignments_active_role_user_index)
  end
end
