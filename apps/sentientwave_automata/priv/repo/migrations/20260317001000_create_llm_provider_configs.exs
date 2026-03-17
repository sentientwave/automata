defmodule SentientwaveAutomata.Repo.Migrations.CreateLlmProviderConfigs do
  use Ecto.Migration

  def change do
    create table(:llm_provider_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :singleton_key, :string, null: false, default: "default"
      add :provider, :string, null: false, default: "local"
      add :model, :string, null: false, default: "local-default"
      add :base_url, :string
      add :api_token, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:llm_provider_configs, [:singleton_key])
  end
end
