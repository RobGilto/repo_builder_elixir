defmodule RepoBuilder.Repo.Migrations.AddHiddenFlagToLogsAndWorkflowRuns do
  use Ecto.Migration

  # Soft-hide flag for the console's CLEAR actions: clearing the log view / finished
  # workflows marks rows hidden so the state survives a reconnect (the rows are NOT
  # deleted — a settings "show hidden" toggle reveals them for troubleshooting).
  def change do
    alter table(:agent_logs) do
      add :hidden, :boolean, null: false, default: false
    end

    alter table(:workflow_runs) do
      add :hidden, :boolean, null: false, default: false
    end

    # Backfill reads filter on `hidden`; index keeps the "visible only" scans cheap.
    create index(:agent_logs, [:hidden])
    create index(:workflow_runs, [:hidden])
  end
end
