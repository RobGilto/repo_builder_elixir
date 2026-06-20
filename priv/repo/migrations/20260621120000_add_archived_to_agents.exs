defmodule RepoBuilder.Repo.Migrations.AddArchivedToAgents do
  use Ecto.Migration

  # Soft-archive support (re-integrated from the db130314 agent-CRUD branch). `model`
  # and `system_prompt` already exist on `agents` (migration
  # 20260616000002_add_orchestrator_fields_to_agents), so this adds ONLY the new
  # `archived` flag plus a partial index that keeps the default (non-archived) list fast.
  def change do
    alter table(:agents) do
      add :archived, :boolean, null: false, default: false
    end

    create index(:agents, [:archived], where: "archived = false", name: :agents_active_index)
  end
end
