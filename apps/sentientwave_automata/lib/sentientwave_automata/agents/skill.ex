defmodule SentientwaveAutomata.Agents.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_skills" do
    field :name, :string
    field :markdown_path, :string
    field :markdown_body, :string
    field :version, :string, default: "v1"
    field :enabled, :boolean, default: true
    field :metadata, :map, default: %{}

    belongs_to :agent, SentientwaveAutomata.Agents.AgentProfile

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :agent_id,
      :name,
      :markdown_path,
      :markdown_body,
      :version,
      :enabled,
      :metadata
    ])
    |> validate_required([:agent_id, :name, :markdown_body, :version])
    |> assoc_constraint(:agent)
    |> unique_constraint(:name, name: :agent_skills_agent_id_name_version_index)
  end
end
