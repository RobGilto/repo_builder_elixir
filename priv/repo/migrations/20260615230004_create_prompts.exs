defmodule RepoBuilder.Repo.Migrations.CreatePrompts do
  use Ecto.Migration

  def change do
    create table(:prompts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :body, :text, null: false
      add :variables, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:prompts, [:name])
  end
end
