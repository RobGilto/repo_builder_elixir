defmodule RepoBuilder.Repo.Migrations.AddWorkflowRunIdToAgentLogs do
  use Ecto.Migration

  def change do
    alter table(:agent_logs) do
      add :workflow_run_id, references(:workflow_runs, type: :binary_id, on_delete: :delete_all)
    end

    create index(:agent_logs, [:workflow_run_id])
  end
end
