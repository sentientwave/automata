defmodule SentientwaveAutomata.Repo.Migrations.CreateGovernanceTables do
  use Ecto.Migration

  def change do
    create table(:governance_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :enabled, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:governance_roles, [:slug])
    create index(:governance_roles, [:enabled])

    create table(:governance_laws, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :slug, :string, null: false
      add :name, :string, null: false
      add :markdown_body, :text, null: false
      add :law_kind, :string, null: false, default: "general"
      add :rule_config, :map, null: false, default: %{}
      add :status, :string, null: false, default: "active"
      add :position, :integer, null: false, default: 100
      add :version, :integer, null: false, default: 1
      add :ratified_at, :utc_datetime_usec
      add :repealed_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      add :created_by_id, references(:directory_users, type: :binary_id, on_delete: :nilify_all)
      add :updated_by_id, references(:directory_users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:governance_laws, [:law_kind, :status, :position])
    create index(:governance_laws, [:status, :position])

    create unique_index(
             :governance_laws,
             [:slug],
             where: "status = 'active'",
             name: :governance_laws_active_slug_index
           )

    create table(:governance_role_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :role_id,
          references(:governance_roles, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:directory_users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false, default: "active"
      add :assigned_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:governance_role_assignments, [:role_id, :status])
    create index(:governance_role_assignments, [:user_id, :status])

    create unique_index(
             :governance_role_assignments,
             [:role_id, :user_id],
             where: "status = 'active'",
             name: :governance_role_assignments_active_role_user_index
           )

    create table(:governance_law_proposals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :reference, :string, null: false

      add :law_id,
          references(:governance_laws, type: :binary_id, on_delete: :nilify_all)

      add :proposal_type, :string, null: false
      add :status, :string, null: false, default: "open"
      add :proposed_slug, :string
      add :proposed_name, :string
      add :proposed_markdown_body, :text
      add :proposed_law_kind, :string, null: false, default: "general"
      add :proposed_rule_config, :map, null: false, default: %{}
      add :reason, :text
      add :voting_scope, :string, null: false, default: "all_members"
      add :voting_rule_snapshot, :map, null: false, default: %{}
      add :opened_at, :utc_datetime_usec, null: false
      add :closes_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec
      add :room_id, :string
      add :proposal_message_id, :string
      add :result_message_id, :string
      add :raw_event, :map, null: false, default: %{}
      add :workflow_id, :string
      add :metadata, :map, null: false, default: %{}

      add :created_by_id, references(:directory_users, type: :binary_id, on_delete: :nilify_all),
        null: false

      add :resolved_by_id, references(:directory_users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:governance_law_proposals, [:reference])
    create unique_index(:governance_law_proposals, [:workflow_id])
    create index(:governance_law_proposals, [:status, :closes_at])
    create index(:governance_law_proposals, [:law_id, :status])
    create index(:governance_law_proposals, [:opened_at])

    create table(:governance_proposal_eligible_roles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :proposal_id,
          references(:governance_law_proposals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :role_id,
          references(:governance_roles, type: :binary_id, on_delete: :delete_all),
          null: false

      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:governance_proposal_eligible_roles, [:proposal_id, :role_id])

    create table(:governance_proposal_electors, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :proposal_id,
          references(:governance_law_proposals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:directory_users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :eligible_via, :string, null: false, default: "all_members"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:governance_proposal_electors, [:proposal_id, :user_id])
    create index(:governance_proposal_electors, [:proposal_id, :eligible_via])

    create table(:governance_law_votes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :proposal_id,
          references(:governance_law_proposals, type: :binary_id, on_delete: :delete_all),
          null: false

      add :voter_id, references(:directory_users, type: :binary_id, on_delete: :delete_all),
        null: false

      add :choice, :string, null: false
      add :cast_at, :utc_datetime_usec, null: false
      add :room_id, :string
      add :message_id, :string
      add :raw_event, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:governance_law_votes, [:proposal_id, :voter_id])
    create index(:governance_law_votes, [:proposal_id, :choice])
    create index(:governance_law_votes, [:proposal_id, :cast_at])

    create table(:governance_constitution_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version, :integer, null: false
      add :prompt_text, :text, null: false
      add :published_at, :utc_datetime_usec, null: false

      add :proposal_id,
          references(:governance_law_proposals, type: :binary_id, on_delete: :nilify_all)

      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:governance_constitution_snapshots, [:version])
    create index(:governance_constitution_snapshots, [:published_at])

    create table(:governance_constitution_snapshot_laws, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :snapshot_id,
          references(:governance_constitution_snapshots,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :law_id,
          references(:governance_laws, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false, default: 100
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:governance_constitution_snapshot_laws, [:snapshot_id, :law_id])
    create index(:governance_constitution_snapshot_laws, [:law_id, :position])
  end
end
