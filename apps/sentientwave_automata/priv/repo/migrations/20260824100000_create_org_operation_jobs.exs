defmodule SentientwaveAutomata.Repo.Migrations.CreateOrgOperationJobs do
  use Ecto.Migration

  def up do
    # Durable async job records for org/chat operations executed as Temporal
    # workflows. workflow_id doubles as the idempotency key: a retried tool
    # call maps onto the same row instead of starting duplicate work.
    create table(:org_operation_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workflow_id, :string, null: false
      add :op, :string, null: false
      add :args, :map, null: false, default: %{}
      add :requested_by, :string
      add :status, :string, null: false, default: "queued"
      add :result, :map
      add :error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:org_operation_jobs, [:workflow_id])
    create index(:org_operation_jobs, [:status])

    # Job status lookup as a visible tool available to every agent.
    execute """
    INSERT INTO tool_configs (id, name, slug, tool_name, base_url, api_token, enabled, metadata, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'Org Job Status', 'org-job-status', 'org_job_status', '', '', true, '{}'::jsonb, now(), now())
    ON CONFLICT (slug) DO NOTHING;
    """

    execute """
    INSERT INTO tool_role_grants (id, tool_name, role, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'org_job_status', 'all', now(), now())
    ON CONFLICT (tool_name, role) DO NOTHING;
    """
  end

  def down do
    execute "DELETE FROM tool_role_grants WHERE tool_name = 'org_job_status';"
    execute "DELETE FROM tool_configs WHERE tool_name = 'org_job_status';"
    drop table(:org_operation_jobs)
  end
end
