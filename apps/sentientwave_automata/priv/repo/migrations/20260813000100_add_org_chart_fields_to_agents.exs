defmodule SentientwaveAutomata.Repo.Migrations.AddOrgChartFieldsToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :sex, :string, null: true
      add :date_of_birth, :date, null: true
      add :company_description, :text, null: true
      add :job_description, :text, null: true
      add :reports_to, :string, null: true
    end

    create index(:agents, [:reports_to])
  end
end
