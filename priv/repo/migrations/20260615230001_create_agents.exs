defmodule RepoBuilder.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      # Open identity, validated vs the registry at the changeset boundary (NOT a DB enum).
      add :harness, :string, null: false
      add :provider, :string, null: false
      add :status, :string, null: false, default: "idle"
      add :config, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agents, [:name])
  end
end
