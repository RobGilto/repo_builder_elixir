defmodule RepoBuilder.Repo.Migrations.AddSystemPromptModeToOrchestrators do
  use Ecto.Migration

  def change do
    # Append/replace mode for the orchestrator system prompt. Stored as a :string
    # (Ecto.Enum-as-string per §8 — no DB enum type). Default "append" preserves the
    # prior hardcoded behavior for every existing row, so no backfill is needed.
    alter table(:orchestrators) do
      add :system_prompt_mode, :string, null: false, default: "append"
    end
  end
end
