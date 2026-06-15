defmodule RepoBuilder.Repo.Migrations.CreateWorkflowRuns do
  use Ecto.Migration

  def change do
    create table(:workflow_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :status, :string, null: false, default: "queued"
      add :current_step, :string
      add :artifacts, :map, default: %{}
      # Nullable: NULL = unpriced (never defaulted to 0).
      add :total_cost_usd, :decimal
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_runs, [:workflow_id])
    create index(:workflow_runs, [:status])
  end
end
