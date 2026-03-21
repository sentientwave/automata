defmodule SentientwaveAutomata.Repo.Migrations.CreateAgentScheduledTasks do
  use Ecto.Migration

  def change do
    create table(:agent_scheduled_tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false

      add :name, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :task_type, :string, null: false
      add :schedule_type, :string, null: false
      add :schedule_interval, :integer, null: false, default: 1
      add :schedule_hour, :integer
      add :schedule_minute, :integer, null: false, default: 0
      add :schedule_weekday, :integer
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :room_id, :string
      add :prompt_body, :text
      add :message_body, :text
      add :next_run_at, :utc_datetime_usec
      add :last_run_at, :utc_datetime_usec
      add :last_outcome, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_scheduled_tasks, [:agent_id])
    create index(:agent_scheduled_tasks, [:enabled, :next_run_at])
    create index(:agent_scheduled_tasks, [:task_type])
  end
end
