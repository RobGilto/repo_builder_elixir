defmodule RepoBuilder.Repo.Migrations.AddReasoningEffortToOrchestrators do
  use Ecto.Migration

  def change do
    # Harness-blind reasoning effort for the orchestrator. Stored as a :string
    # (Ecto.Enum-as-string per §8 — no DB enum type). Default "default" means "omit
    # the per-harness effort flag", preserving prior behavior for every existing row,
    # so no backfill is needed.
    alter table(:orchestrators) do
      add :reasoning_effort, :string, null: false, default: "default"
    end
  end
end
