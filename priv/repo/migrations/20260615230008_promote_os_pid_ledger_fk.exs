defmodule RepoBuilder.Repo.Migrations.PromoteOsPidLedgerFk do
  use Ecto.Migration

  # M3: promote os_pid_ledger.agent_id (plain binary_id in M2) to a real FK now that
  # the agents table exists. :nilify_all keeps a ledger row reapable even if its
  # agent is deleted mid-flight.
  def change do
    alter table(:os_pid_ledger) do
      modify :agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all),
        from: :binary_id
    end
  end
end
