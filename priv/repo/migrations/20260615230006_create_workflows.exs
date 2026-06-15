defmodule RepoBuilder.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :state, :string, null: false, default: "draft"
      # Ordered list of step maps (jsonb[]).
      add :steps, {:array, :map}, default: []
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workflows, [:name])
  end
end
