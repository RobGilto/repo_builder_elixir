defmodule RepoBuilder.Repo.Migrations.CreateOrchestratorWorkstreams do
  use Ecto.Migration

  @moduledoc """
  Spec-driven, phased, parallel WORKSTREAM orchestration (orchestration-adw-loop).

  A Workstream is the orchestrator's top-level durable unit of work — its goal /
  definition-of-done, lifecycle `status`, `stall_count`, and `current_phase_position`,
  plus an ordered Pipeline of phases. Each phase carries its `spec_path` and a JSONB
  `stages` map (`spec|implement|test|review` → `%{status, worker, artifact, note}`)
  driving the per-phase spec→implement→test→review machine.

  Multiple workstreams can be active for one orchestrator at once (the parallel-workstream
  scheduler), so — unlike the single-goal `task_ledgers` — there is NO "one active per
  orchestrator" constraint. The legacy `task_ledgers_one_active_per_orchestrator` index is
  left UNTOUCHED: Workstreams are a separate, parallel structure and never write
  `task_ledgers`, so the lowest-churn option (per task 1 Notes) is no migration of the
  legacy table at all. binary_id PKs; FKs delete_all; additive and reversible.
  """

  def change do
    create table(:orchestrator_workstreams, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :orchestrator_id,
          references(:orchestrators, type: :binary_id, on_delete: :delete_all),
          null: false

      add :title, :string, null: false
      add :goal, :text, null: false
      add :definition_of_done, :text
      add :status, :string, null: false, default: "running"
      add :stall_count, :integer, null: false, default: 0
      add :current_phase_position, :integer, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestrator_workstreams, [:orchestrator_id])

    create table(:orchestrator_workstream_phases, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workstream_id,
          references(:orchestrator_workstreams, type: :binary_id, on_delete: :delete_all),
          null: false

      add :position, :integer, null: false
      add :title, :string, null: false
      add :description, :text
      add :definition_of_done, :text
      add :spec_path, :string
      # jsonb stage map: `%{"spec" => %{"status" => ..., "worker" => ..., ...}, ...}`.
      add :stages, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :current_stage, :string, null: false, default: "spec"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:orchestrator_workstream_phases, [:workstream_id, :position])
  end
end
