defmodule SentientwaveAutomata.Repo.Migrations.CreateToolConfigs do
  use Ecto.Migration

  def change do
    create table(:tool_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false, default: "Brave Search"
      add :slug, :string, null: false, default: "brave-search"
      add :tool_name, :string, null: false, default: "brave_search"
      add :base_url, :string
      add :api_token, :text
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tool_configs, [:slug])
  end
end
