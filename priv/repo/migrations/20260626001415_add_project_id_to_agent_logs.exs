defmodule RepoBuilder.Repo.Migrations.AddProjectIdToAgentLogs do
  use Ecto.Migration

  # Nullable project attribution for the durable cost ledger (issue per-project-cost-
  # tracking). `nilify_all` mirrors the agents/workflow_runs pattern: deleting a project
  # never destroys its cost history; the row simply becomes unscoped (NULL = the platform).
  # Pre-existing rows stay NULL (no backfill) and are excluded from any project total.
  def change do
    alter table(:agent_logs) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:agent_logs, [:project_id])
  end
end
