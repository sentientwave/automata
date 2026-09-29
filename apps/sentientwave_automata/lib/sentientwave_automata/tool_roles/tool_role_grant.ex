defmodule SentientwaveAutomata.ToolRoles.ToolRoleGrant do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "tool_role_grants" do
    field :tool_name, :string
    field :role, :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(grant, attrs) do
    grant
    |> cast(attrs, [:tool_name, :role])
    |> validate_required([:tool_name, :role])
    |> unique_constraint([:tool_name, :role])
  end
end
