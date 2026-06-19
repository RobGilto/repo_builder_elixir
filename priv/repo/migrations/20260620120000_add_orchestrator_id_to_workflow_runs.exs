defmodule RepoBuilder.Repo.Migrations.AddOrchestratorIdToWorkflowRuns do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      # Links a WorkflowEngine ADW run back to the orchestrator that launched it
      # (issue-fallback) so the run's terminal site can emit the holding-pattern
      # worker-terminal wakeup. Nullable: most runs are NOT orchestrator-launched
      # (durable Oban path, manual runs) and stay NULL. `nilify_all` so deleting an
      # orchestrator never cascades away its historical runs.
      add :orchestrator_id,
          references(:orchestrators, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:workflow_runs, [:orchestrator_id])
  end
end
