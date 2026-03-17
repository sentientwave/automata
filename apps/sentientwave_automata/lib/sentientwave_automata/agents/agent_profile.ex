defmodule SentientwaveAutomata.Agents.AgentProfile do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :slug, :string
    field :kind, Ecto.Enum, values: [:person, :agent]
    field :display_name, :string
    field :matrix_localpart, :string
    field :status, Ecto.Enum, values: [:active, :disabled], default: :active
    field :metadata, :map, default: %{}

    has_many :skills, SentientwaveAutomata.Agents.Skill, foreign_key: :agent_id
    has_many :memories, SentientwaveAutomata.Agents.Memory, foreign_key: :agent_id
    has_many :mentions, SentientwaveAutomata.Agents.Mention, foreign_key: :mentioned_agent_id
    has_many :runs, SentientwaveAutomata.Agents.Run, foreign_key: :agent_id
    has_many :tool_permissions, SentientwaveAutomata.Agents.ToolPermission, foreign_key: :agent_id
    has_one :wallet, SentientwaveAutomata.Agents.AgentWallet, foreign_key: :agent_id

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:slug, :kind, :display_name, :matrix_localpart, :status, :metadata])
    |> validate_required([:slug, :kind, :matrix_localpart, :status])
    |> unique_constraint(:slug)
    |> unique_constraint(:matrix_localpart)
  end
end
