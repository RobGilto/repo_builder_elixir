defmodule RepoBuilder.Repo.Migrations.AddTokenUsageToOrchestrators do
  use Ecto.Migration

  def change do
    alter table(:orchestrators) do
      # Cumulative lifetime throughput (for the cost report).
      add :input_tokens, :bigint, null: false, default: 0
      add :output_tokens, :bigint, null: false, default: 0
      # Latest-turn input+output — the context-window OCCUPANCY signal (overwritten
      # each Event.Usage, NOT accumulated).
      add :context_tokens, :bigint, null: false, default: 0
    end
  end
end
