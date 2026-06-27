defmodule RepoBuilder.Repo.Migrations.CreateOrchestratorReflections do
  use Ecto.Migration

  @moduledoc """
  Verbal self-improving memory (self-healing orchestrator, Phase 5 — Reflexion). After a goal
  completes or escalates, the orchestrator writes a one-line `lesson` (scoped to its
  `project_id` + the `goal`); `SystemPrompt` injects the last N for the project on the next
  run, so each run starts ahead of where the last one ended. Nullable scope columns
  (`project_id`/`orchestrator_id`) so a platform/unbound orchestrator can still reflect.
  binary_id PK; additive.
  """

  def change do
    create table(:orchestrator_reflections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)

      add :orchestrator_id,
          references(:orchestrators, type: :binary_id, on_delete: :delete_all)

      add :goal, :text
      add :lesson, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestrator_reflections, [:project_id])
    create index(:orchestrator_reflections, [:orchestrator_id])
  end
end
