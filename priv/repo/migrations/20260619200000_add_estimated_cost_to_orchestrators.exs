defmodule RepoBuilder.Repo.Migrations.AddEstimatedCostToOrchestrators do
  use Ecto.Migration

  def change do
    alter table(:orchestrators) do
      # Token-derived live cost ESTIMATE (display-only, OVERWRITE-latest snapshot).
      # Nullable: NULL = unpriced/no estimate yet, distinct from a priced 0. Superseded
      # by the authoritative `total_cost_usd` when the harness reports the billed amount.
      add :estimated_cost_usd, :numeric
    end
  end
end
