defmodule RepoBuilder.Repo.Migrations.RenameSeqNoToLogNoOnAgentLogs do
  use Ecto.Migration

  @moduledoc """
  Pure rename of the durable per-row identifier `agent_logs.seq_no` → `log_no` so the
  friendly name (`log-<n>`, already used by the web layer) is consistent end-to-end
  from the database through to the console drilldown. NO data change, no new semantics.

  The column keeps its owned sequence + `DEFAULT nextval(...)` (Postgres tracks the
  sequence by OID, so renaming the column does not break the default). The owned
  sequence and unique index are also renamed so DB object names match the new column
  name — cosmetic-but-correct for the troubleshooting audience this serves.

  Explicit `up/0`/`down/0` (not a reversible `change/0`) because the raw
  `ALTER SEQUENCE/INDEX RENAME` statements are not auto-reversible.
  """

  def up do
    rename table(:agent_logs), :seq_no, to: :log_no
    execute("ALTER SEQUENCE agent_logs_seq_no_seq RENAME TO agent_logs_log_no_seq")
    execute("ALTER INDEX agent_logs_seq_no_index RENAME TO agent_logs_log_no_index")
  end

  def down do
    execute("ALTER INDEX agent_logs_log_no_index RENAME TO agent_logs_seq_no_index")
    execute("ALTER SEQUENCE agent_logs_log_no_seq RENAME TO agent_logs_seq_no_seq")
    rename table(:agent_logs), :log_no, to: :seq_no
  end
end
