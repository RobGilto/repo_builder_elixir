defmodule RepoBuilder.Repo.Migrations.CreateBudgets do
  use Ecto.Migration

  def change do
    create table(:budgets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :scope, :string, null: false
      # "" sentinel for the global scope (mirrors CostCenter's normalize_provider/1),
      # so the unique key stays total and NULL-free.
      add :scope_id, :string, null: false, default: ""
      add :period, :string, null: false, default: "total"
      add :limit_usd, :decimal, precision: 15, scale: 6, null: false
      add :warn_ratio, :float, null: false, default: 0.8
      add :action, :string, null: false, default: "alert"
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:budgets, [:scope, :scope_id, :period], name: :budgets_scope_period_index)
  end
end
