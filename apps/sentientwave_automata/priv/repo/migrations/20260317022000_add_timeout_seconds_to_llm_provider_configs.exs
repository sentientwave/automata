defmodule SentientwaveAutomata.Repo.Migrations.AddTimeoutSecondsToLlmProviderConfigs do
  use Ecto.Migration

  def change do
    alter table(:llm_provider_configs) do
      add :timeout_seconds, :integer, null: false, default: 600
    end
  end
end
