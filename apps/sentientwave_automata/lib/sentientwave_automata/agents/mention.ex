defmodule SentientwaveAutomata.Agents.Mention do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses [:pending, :processing, :completed, :failed, :ignored]

  schema "agent_mentions" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :room_id, :string
    field :sender_mxid, :string
    field :message_id, :string
    field :body, :string
    field :processed_at, :utc_datetime_usec
    field :raw_event, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :mentioned_agent, SentientwaveAutomata.Agents.AgentProfile
    has_many :runs, SentientwaveAutomata.Agents.Run, foreign_key: :mention_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(mention, attrs) do
    mention
    |> cast(attrs, [
      :mentioned_agent_id,
      :status,
      :room_id,
      :sender_mxid,
      :message_id,
      :body,
      :processed_at,
      :raw_event,
      :metadata
    ])
    |> validate_required([:room_id, :sender_mxid, :message_id, :body, :status])
    |> assoc_constraint(:mentioned_agent)
    |> unique_constraint(:message_id, name: :agent_mentions_message_id_mentioned_agent_id_index)
  end
end
