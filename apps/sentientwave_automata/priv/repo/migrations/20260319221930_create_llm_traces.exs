defmodule SentientwaveAutomata.Repo.Migrations.CreateLlmTraces do
  use Ecto.Migration

  def change do
    create table(:llm_traces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :run_id, references(:agent_runs, type: :binary_id, on_delete: :nilify_all)
      add :mention_id, references(:agent_mentions, type: :binary_id, on_delete: :nilify_all)

      add :provider_config_id,
          references(:llm_provider_configs, type: :binary_id, on_delete: :nilify_all)

      add :provider, :string, null: false
      add :model, :string, null: false
      add :call_kind, :string, null: false, default: "response"
      add :sequence_index, :integer, null: false, default: 0
      add :status, :string, null: false, default: "ok"

      add :requester_id, :string
      add :requester_kind, :string
      add :requester_localpart, :string
      add :requester_mxid, :string
      add :requester_display_name, :string

      add :room_id, :string
      add :conversation_scope, :string, null: false, default: "unknown"
      add :remote_ip, :string

      add :request_payload, :map, null: false, default: %{}
      add :response_payload, :map
      add :error_payload, :map

      add :requested_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:llm_traces, [:agent_id, :requested_at])
    create index(:llm_traces, [:run_id])
    create index(:llm_traces, [:mention_id])
    create index(:llm_traces, [:provider, :inserted_at])
    create index(:llm_traces, [:requester_mxid])
    create index(:llm_traces, [:room_id])
    create index(:llm_traces, [:status])
  end
end
