defmodule RepoBuilder.Repo.Migrations.CreateAgentLogs do
  use Ecto.Migration

  def change do
    create table(:agent_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :session_id, :string
      add :event_type, :string, null: false
      add :harness, :string
      # Secret-redacted raw wire frame (jsonb).
      add :payload, :map, default: %{}
      # Embedded Usage value object (jsonb, nullable).
      add :usage, :map
      timestamps(type: :utc_datetime_usec)
    end

    create index(:agent_logs, [:agent_id])
    create index(:agent_logs, [:session_id])
  end
end
