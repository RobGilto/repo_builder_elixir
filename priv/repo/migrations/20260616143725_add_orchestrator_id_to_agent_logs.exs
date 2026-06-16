defmodule RepoBuilder.Repo.Migrations.AddOrchestratorIdToAgentLogs do
  use Ecto.Migration

  def change do
    alter table(:agent_logs) do
      # Orchestrator-scoped persistence (issue-d): an orchestrator turn's canonical
      # events persist here keyed by orchestrator_id instead of agent_id, so
      # reconnect-backfill and cost rollups include orchestrator turns identically
      # to workers. Exactly one of agent_id/orchestrator_id is set (app-enforced).
      add :orchestrator_id,
          references(:orchestrators, type: :binary_id, on_delete: :delete_all)

      # Was null: false — relaxed so an orchestrator log validates without an agent.
      modify :agent_id, :binary_id, null: true
    end

    create index(:agent_logs, [:orchestrator_id])
  end
end
