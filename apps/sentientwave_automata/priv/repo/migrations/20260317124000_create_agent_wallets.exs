defmodule SentientwaveAutomata.Repo.Migrations.CreateAgentWallets do
  use Ecto.Migration

  def change do
    create table(:agent_wallets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :wallet_ref, :string, null: false
      add :kind, :string, null: false, default: "personal"
      add :status, :string, null: false, default: "active"
      add :balance, :bigint, null: false, default: 0
      add :matrix_credentials, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_wallets, [:agent_id])
    create unique_index(:agent_wallets, [:wallet_ref])
  end
end
