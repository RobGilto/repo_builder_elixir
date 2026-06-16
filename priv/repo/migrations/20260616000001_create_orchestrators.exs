defmodule RepoBuilder.Repo.Migrations.CreateOrchestrators do
  use Ecto.Migration

  def change do
    create table(:orchestrators, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      # Open identity, validated vs the registry at the changeset boundary (NOT a DB enum).
      add :harness, :string, null: false
      add :model, :string
      # Resumable CLI session id (Claude --resume / pi --session); nil on first turn.
      add :session_id, :string
      add :system_prompt, :text
      add :status, :string, null: false, default: "idle"
      add :working_dir, :string
      # Decimal money column (§8 float→Decimal boundary).
      add :total_cost_usd, :decimal, null: false, default: 0
      # SHA-256 of the per-orchestrator bearer token (plaintext NEVER stored).
      add :token_hash, :string
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:orchestrators, [:name])
  end
end
