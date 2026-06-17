defmodule RepoBuilder.Repo.Migrations.AddWorkflowTypeAndStepStates do
  use Ecto.Migration

  def change do
    # The catalog slug this workflow was built from (free-form; the catalog validates
    # membership at the tool boundary). Nullable — no backfill for existing rows.
    alter table(:workflows) do
      add :type, :string
    end

    # Per-step observability map: %{step_name => %{status, started_at, finished_at,
    # cost_usd}}. Authoritative per-step view, written by both the live Runner and the
    # durable StepWorker. Non-null with an empty default so reads never see nil.
    alter table(:workflow_runs) do
      add :step_states, :map, null: false, default: %{}
    end
  end
end
