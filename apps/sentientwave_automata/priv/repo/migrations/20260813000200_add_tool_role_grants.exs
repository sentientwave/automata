defmodule SentientwaveAutomata.Repo.Migrations.AddToolRoleGrants do
  use Ecto.Migration

  def up do
    create table(:tool_role_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :tool_name, :string, null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tool_role_grants, [:tool_name, :role])

    # Matrix messaging tools as visible tool configs in the Tools section.
    execute """
    INSERT INTO tool_configs (id, name, slug, tool_name, base_url, api_token, enabled, metadata, inserted_at, updated_at)
    VALUES
      (gen_random_uuid(), 'Send Matrix Message', 'send-matrix-message', 'send_matrix_message', '', '', true, '{}'::jsonb, now(), now()),
      (gen_random_uuid(), 'Create Matrix Room', 'create-matrix-room', 'create_matrix_room', '', '', true, '{}'::jsonb, now(), now()),
      (gen_random_uuid(), 'Delete Matrix Room', 'delete-matrix-room', 'delete_matrix_room', '', '', true, '{}'::jsonb, now(), now())
    ON CONFLICT (slug) DO NOTHING;
    """

    # Default role mapping for the matrix tools.
    execute """
    INSERT INTO tool_role_grants (id, tool_name, role, inserted_at, updated_at)
    SELECT gen_random_uuid(), g.tool_name, g.role, now(), now()
    FROM (VALUES
      ('send_matrix_message', 'all'),
      ('create_matrix_room', 'executive'),
      ('create_matrix_room', 'department_head'),
      ('delete_matrix_room', 'executive')
    ) AS g(tool_name, role)
    ON CONFLICT (tool_name, role) DO NOTHING;
    """
  end

  def down do
    execute "DELETE FROM tool_role_grants;"
    drop unique_index(:tool_role_grants, [:tool_name, :role])
    drop table(:tool_role_grants)
  end
end
