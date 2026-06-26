defmodule RepoBuilder.Repo.Migrations.CreateAppSettings do
  use Ecto.Migration

  def change do
    create table(:app_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:app_settings, [:key])
  end
end
