defmodule RepoBuilder.Repo.Migrations.AddFocusToOrchestratorFocusState do
  use Ecto.Migration

  def change do
    alter table(:task_ledgers) do
      add :focus, :text
      add :focus_set_at, :utc_datetime_usec
    end

    alter table(:orchestrator_workstreams) do
      add :focus, :text
      add :focus_set_at, :utc_datetime_usec
    end
  end
end
