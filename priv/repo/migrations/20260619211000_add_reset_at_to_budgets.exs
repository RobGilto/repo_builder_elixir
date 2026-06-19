defmodule RepoBuilder.Repo.Migrations.AddResetAtToBudgets do
  use Ecto.Migration

  # `reset_at` marks an operator-chosen spend-window restart: the Guard counts spend
  # only from `max(period_start, reset_at)`, so the "Reset" button on a tripped cap
  # actually clears it (issue-budget-guardrails). NULL = never reset (count from
  # period start, today's behaviour).
  def change do
    alter table(:budgets) do
      add :reset_at, :utc_datetime_usec
    end
  end
end
