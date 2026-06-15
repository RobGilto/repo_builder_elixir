defmodule RepoBuilder.Repo.Migrations.CreateSystemLogs do
  use Ecto.Migration

  def change do
    create table(:system_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :level, :string, null: false
      add :message, :string, null: false
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:system_logs, [:level])
    create index(:system_logs, [:inserted_at])
  end
end
