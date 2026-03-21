defmodule SentientwaveAutomata.Repo.Migrations.CreateDirectoryUsers do
  use Ecto.Migration

  def change do
    create table(:directory_users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :localpart, :string, null: false
      add :kind, :string, null: false, default: "person"
      add :display_name, :string
      add :password, :string, null: false
      add :admin, :boolean, null: false, default: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:directory_users, [:localpart])
    create index(:directory_users, [:kind])
    create index(:directory_users, [:inserted_at])
  end
end
