defmodule RepoBuilder.Repo.Migrations.CreateOsPidLedger do
  use Ecto.Migration

  def change do
    create table(:os_pid_ledger, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Plain binary_id in M2; promoted to a real FK to :agents in M3.
      add :agent_id, :binary_id
      add :session_id, :string, null: false
      add :os_pid, :integer, null: false
      # Also injected as REPO_BUILDER_SESSION_MARKER env on the child.
      add :marker, :string, null: false
      add :argv_hash, :string
      add :node, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
    end

    create unique_index(:os_pid_ledger, [:marker])
    create index(:os_pid_ledger, [:node])
  end
end
