defmodule RepoBuilder.Repo.Migrations.AddProjectIdToOrchestrators do
  use Ecto.Migration

  @moduledoc """
  Orchestrator↔project binding (Phase 1): add a NULLABLE `project_id` FK to
  `orchestrators` so each project gets (and reuses) its own orchestrator row —
  carrying an independent `session_id`/`context_tokens`, i.e. its own context window.
  Mirrors the agents/workflow_runs scoping block from `20260623000001`
  (`on_delete: :nilify_all`): deleting a project downgrades its orchestrator to a
  `project_id: nil` "platform" orchestrator rather than orphaning it. A partial-unique
  index enforces AT MOST ONE orchestrator per project (NULLs are unconstrained, so the
  existing `project_id: nil` platform default is untouched). Fully additive/reversible.
  """

  def change do
    alter table(:orchestrators) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:orchestrators, [:project_id])

    create unique_index(:orchestrators, [:project_id],
             where: "project_id IS NOT NULL",
             name: :orchestrators_project_id_unique
           )
  end
end
