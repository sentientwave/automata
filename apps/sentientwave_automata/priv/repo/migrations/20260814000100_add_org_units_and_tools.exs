defmodule SentientwaveAutomata.Repo.Migrations.AddOrgUnitsAndTools do
  use Ecto.Migration

  def up do
    create table(:org_units, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :kind, :string, null: false, default: "team"
      add :department, :string
      add :mission, :text
      add :head, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:org_units, [:name, :kind])

    # Backfill departments and teams from existing agent metadata.
    execute """
    INSERT INTO org_units (id, name, kind, department, mission, head, inserted_at, updated_at)
    SELECT gen_random_uuid(), d.department, 'department', NULL, NULL, NULL, now(), now()
    FROM (SELECT DISTINCT metadata->>'department' AS department FROM agents
          WHERE metadata->>'department' IS NOT NULL AND metadata->>'department' <> '') d
    ON CONFLICT (name, kind) DO NOTHING;
    """

    execute """
    INSERT INTO org_units (id, name, kind, department, mission, head, inserted_at, updated_at)
    SELECT gen_random_uuid(), t.team, 'team', t.department, NULL, NULL, now(), now()
    FROM (SELECT DISTINCT metadata->>'team' AS team, metadata->>'department' AS department FROM agents
          WHERE metadata->>'team' IS NOT NULL AND metadata->>'team' <> '') t
    ON CONFLICT (name, kind) DO NOTHING;
    """

    # Org structure tools as visible tool configs in the Tools section.
    execute """
    INSERT INTO tool_configs (id, name, slug, tool_name, base_url, api_token, enabled, metadata, inserted_at, updated_at)
    VALUES
      (gen_random_uuid(), 'Create Department', 'create-department', 'create_department', '', '', true, '{}'::jsonb, now(), now()),
      (gen_random_uuid(), 'Create Team', 'create-team', 'create_team', '', '', true, '{}'::jsonb, now(), now()),
      (gen_random_uuid(), 'Set Reports To', 'set-reports-to', 'set_reports_to', '', '', true, '{}'::jsonb, now(), now()),
      (gen_random_uuid(), 'Assign Org Unit', 'assign-org-unit', 'assign_org_unit', '', '', true, '{}'::jsonb, now(), now())
    ON CONFLICT (slug) DO NOTHING;
    """

    # Role mapping: org structure tools -> executive.
    execute """
    INSERT INTO tool_role_grants (id, tool_name, role, inserted_at, updated_at)
    SELECT gen_random_uuid(), g.tool_name, 'executive', now(), now()
    FROM (VALUES
      ('create_department'),
      ('create_team'),
      ('set_reports_to'),
      ('assign_org_unit')
    ) AS g(tool_name)
    ON CONFLICT (tool_name, role) DO NOTHING;
    """
  end

  def down do
    drop table(:org_units)
  end
end
