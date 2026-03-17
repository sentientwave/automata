defmodule SentientwaveAutomata.Repo.Migrations.CreateAgentsRuntimeTables do
  use Ecto.Migration

  def up do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :kind, :string, null: false, default: "agent"
      add :display_name, :string
      add :matrix_localpart, :string
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:slug])
    create unique_index(:agents, [:matrix_localpart])

    create table(:agent_skills, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :markdown_path, :string
      add :markdown_body, :text, null: false
      add :version, :string, null: false, default: "v1"
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_skills, [:agent_id, :name, :version])

    create table(:agent_tool_permissions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :tool_name, :string, null: false
      add :scope, :string, null: false, default: "default"
      add :allowed, :boolean, null: false, default: false
      add :constraints, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_tool_permissions, [:agent_id, :tool_name, :scope])

    create table(:agent_memories, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :content, :text, null: false
      add :source, :string
      add :embedding, {:array, :float}, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:agent_memories, [:agent_id])
    create index(:agent_memories, [:inserted_at])

    create table(:agent_mentions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :mentioned_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :room_id, :string, null: false
      add :sender_mxid, :string, null: false
      add :message_id, :string, null: false
      add :body, :text, null: false
      add :status, :string, null: false, default: "pending"
      add :raw_event, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :processed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:agent_mentions, [:message_id, :mentioned_agent_id])
    create index(:agent_mentions, [:status])
    create index(:agent_mentions, [:room_id])

    create table(:agent_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all), null: false

      add :mention_id, references(:agent_mentions, type: :binary_id, on_delete: :nilify_all)
      add :workflow_id, :string, null: false
      add :temporal_run_id, :string
      add :status, :string, null: false, default: "queued"
      add :error, :map
      add :result, :map
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_runs, [:workflow_id])
    create index(:agent_runs, [:status])
    create index(:agent_runs, [:agent_id, :inserted_at])
  end

  def down do
    drop table(:agent_runs)
    drop table(:agent_mentions)
    drop table(:agent_memories)
    drop table(:agent_tool_permissions)
    drop table(:agent_skills)
    drop table(:agents)
  end
end
