defmodule SentientwaveAutomata.Agents.ToolPermission do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_tool_permissions" do
    field :tool_name, :string
    field :scope, :string, default: "default"
    field :allowed, :boolean, default: false
    field :constraints, :map, default: %{}

    belongs_to :agent, SentientwaveAutomata.Agents.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(permission, attrs) do
    permission
    |> cast(attrs, [:agent_id, :tool_name, :scope, :allowed, :constraints])
    |> validate_required([:agent_id, :tool_name, :scope])
    |> assoc_constraint(:agent)
    |> unique_constraint(:tool_name, name: :agent_tool_permissions_agent_id_tool_name_scope_index)
  end
end
