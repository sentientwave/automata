defmodule SentientwaveAutomata.Repo.Migrations.EnableMultipleLlmProviderConfigs do
  use Ecto.Migration

  def up do
    alter table(:llm_provider_configs) do
      add :name, :string, null: false, default: "Primary"
      add :slug, :string, null: false, default: "primary"
      add :enabled, :boolean, null: false, default: true
      add :is_default, :boolean, null: false, default: false
    end

    execute "DROP INDEX IF EXISTS llm_provider_configs_singleton_key_index"
    create unique_index(:llm_provider_configs, [:slug])

    execute """
    UPDATE llm_provider_configs
    SET name = COALESCE(NULLIF(name, ''), 'Primary'),
        slug = COALESCE(NULLIF(slug, ''), 'primary')
    """

    execute """
    UPDATE llm_provider_configs
    SET is_default = true
    WHERE id IN (
      SELECT id
      FROM llm_provider_configs
      ORDER BY inserted_at ASC
      LIMIT 1
    )
    """

    execute """
    CREATE UNIQUE INDEX llm_provider_configs_single_default_index
    ON llm_provider_configs ((is_default))
    WHERE is_default = true
    """
  end

  def down do
    execute "DROP INDEX IF EXISTS llm_provider_configs_single_default_index"
    drop_if_exists unique_index(:llm_provider_configs, [:slug])
    create unique_index(:llm_provider_configs, [:singleton_key])

    alter table(:llm_provider_configs) do
      remove :is_default
      remove :enabled
      remove :slug
      remove :name
    end
  end
end
