defmodule RepoBuilder.Repo.Migrations.CreateTaskLedgers do
  use Ecto.Migration

  @moduledoc """
  The durable Task Ledger (self-healing orchestrator, Phase 3 — Magentic-One dual-ledger).
  One row per goal an orchestrator is driving: the objective, known facts, guesses, a jsonb
  step plan, the definition-of-done, a lifecycle `status`, and a `stall_count`. An
  orchestrator has at most ONE `:active` ledger at a time (a partial unique index enforces
  it). FK to orchestrator (delete_all) + nullable project (nilify). binary_id PK; additive.
  """

  def change do
    create table(:task_ledgers, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :orchestrator_id,
          references(:orchestrators, type: :binary_id, on_delete: :delete_all),
          null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
      add :goal, :text, null: false
      add :definition_of_done, :text, null: false
      add :facts, :text
      add :guesses, :text
      # jsonb step plan: a list of `%{"step" => ..., "status" => ...}` maps (the schema
      # defaults it to `[]`; jsonb holds the array).
      add :plan, :map
      add :status, :string, null: false, default: "active"
      add :stall_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create index(:task_ledgers, [:orchestrator_id])

    # At most one ACTIVE ledger per orchestrator (the goal currently being driven). Completed
    # / escalated / abandoned ledgers accumulate as history without blocking a new goal.
    create unique_index(:task_ledgers, [:orchestrator_id],
             where: "status = 'active'",
             name: :task_ledgers_one_active_per_orchestrator
           )
  end
end
