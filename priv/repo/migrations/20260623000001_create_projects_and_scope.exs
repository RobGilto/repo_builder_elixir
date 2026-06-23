defmodule RepoBuilder.Repo.Migrations.CreateProjectsAndScope do
  use Ecto.Migration

  @moduledoc """
  Agentic-layer adaptor: promote the target repo to a first-class `projects` entity,
  add a durable `plans` artifact table, and scope existing records with a NULLABLE
  `project_id` FK (nil = "the platform itself", today's behaviour). Fully additive
  and reversible.
  """

  def change do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :root_path, :string, null: false
      add :git_remote, :string
      add :default_branch, :string
      add :stack, :map, default: %{}
      add :capabilities, :map, default: %{}
      add :command_pack, :string, null: false, default: "auto"
      add :command_pack_version, :string, null: false, default: "latest"
      # Open identity, validated vs the registry at the changeset boundary (NOT a DB enum).
      add :default_harness, :string
      add :default_model_tier, :string
      add :budget_cap_usd, :decimal
      add :isolation_mode, :string, null: false, default: "direct"
      add :context_primer, :text
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:name])

    # Durable Plan artifact (Phase 6 writes it; table defined now so the schema is stable).
    create table(:plans, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :goal, :text, null: false
      add :workflow_type, :string, null: false
      add :resolved_steps, :map, default: %{}
      add :estimate, :map, default: %{}
      add :status, :string, null: false, default: "draft"
      # Linked once the plan is launched (nilify so deleting a run keeps the plan).
      add :workflow_run_id,
          references(:workflow_runs, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:plans, [:project_id])
    create index(:plans, [:workflow_run_id])

    # Nullable scoping FK on the existing roster/run tables. `nilify_all` so deleting
    # a project never cascades away historical agents/runs (they revert to unscoped).
    alter table(:agents) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:workflow_runs) do
      add :project_id, references(:projects, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:agents, [:project_id])
    create index(:workflow_runs, [:project_id])
  end
end
