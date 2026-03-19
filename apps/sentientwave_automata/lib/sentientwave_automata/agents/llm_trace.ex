defmodule SentientwaveAutomata.Agents.LLMTrace do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "llm_traces" do
    field :provider, :string
    field :model, :string
    field :call_kind, :string, default: "response"
    field :sequence_index, :integer, default: 0
    field :status, :string, default: "ok"

    field :requester_id, :string
    field :requester_kind, :string
    field :requester_localpart, :string
    field :requester_mxid, :string
    field :requester_display_name, :string

    field :room_id, :string
    field :conversation_scope, :string, default: "unknown"
    field :remote_ip, :string

    field :request_payload, :map, default: %{}
    field :response_payload, :map
    field :error_payload, :map

    field :requested_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :agent, SentientwaveAutomata.Agents.AgentProfile
    belongs_to :run, SentientwaveAutomata.Agents.Run
    belongs_to :mention, SentientwaveAutomata.Agents.Mention
    belongs_to :provider_config, SentientwaveAutomata.Settings.LLMProviderConfig

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(trace, attrs) do
    trace
    |> cast(attrs, [
      :agent_id,
      :run_id,
      :mention_id,
      :provider_config_id,
      :provider,
      :model,
      :call_kind,
      :sequence_index,
      :status,
      :requester_id,
      :requester_kind,
      :requester_localpart,
      :requester_mxid,
      :requester_display_name,
      :room_id,
      :conversation_scope,
      :remote_ip,
      :request_payload,
      :response_payload,
      :error_payload,
      :requested_at,
      :completed_at
    ])
    |> validate_required([
      :provider,
      :model,
      :call_kind,
      :sequence_index,
      :status,
      :conversation_scope,
      :request_payload,
      :requested_at
    ])
    |> validate_length(:provider, min: 1, max: 120)
    |> validate_length(:model, min: 1, max: 200)
    |> validate_length(:call_kind, min: 1, max: 120)
    |> validate_inclusion(:status, ["ok", "error"])
    |> validate_inclusion(:conversation_scope, ["unknown", "room", "private_message"])
    |> assoc_constraint(:agent)
    |> assoc_constraint(:run)
    |> assoc_constraint(:mention)
    |> assoc_constraint(:provider_config)
  end
end
