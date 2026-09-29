defmodule SentientwaveAutomata.Repo.Migrations.AddDestroyDepartmentTool do
  use Ecto.Migration

  def up do
    # Destroy Department as a visible tool config in the Tools section.
    execute """
    INSERT INTO tool_configs (id, name, slug, tool_name, base_url, api_token, enabled, metadata, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'Destroy Department', 'destroy-department', 'destroy_department', '', '', true, '{}'::jsonb, now(), now())
    ON CONFLICT (slug) DO NOTHING;
    """

    # Role mapping: executive only.
    execute """
    INSERT INTO tool_role_grants (id, tool_name, role, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'destroy_department', 'executive', now(), now())
    ON CONFLICT (tool_name, role) DO NOTHING;
    """
  end

  def down do
    execute "DELETE FROM tool_role_grants WHERE tool_name = 'destroy_department';"
    execute "DELETE FROM tool_configs WHERE tool_name = 'destroy_department';"
  end
end
