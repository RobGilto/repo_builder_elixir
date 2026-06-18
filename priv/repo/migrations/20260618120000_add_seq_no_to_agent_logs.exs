defmodule RepoBuilder.Repo.Migrations.AddSeqNoToAgentLogs do
  use Ecto.Migration

  @moduledoc """
  Give every `agent_logs` row a durable, human-readable, best-effort-chronological
  number (`log-<n>`) backed by a Postgres `BIGSERIAL`-style owned sequence. The random
  v4 UUID PK stays the stable join key; `seq_no` is the readable, ordered identifier an
  operator can quote (unlike the 36-char id or the per-socket console `seq`).

  `up` adds the column, backfills existing rows deterministically in `(inserted_at, id)`
  (chronological) order, attaches an owned sequence as the column `DEFAULT` starting after
  the current max, marks the column `NOT NULL`, and adds a unique index. New inserts
  auto-assign the next value (insert/commit order). Fully reversible.
  """

  def up do
    alter table(:agent_logs) do
      add :seq_no, :bigint
    end

    # Deterministic chronological backfill: historical rows get numbers in
    # (inserted_at, id) order so the number carries the chronological signal the UUID
    # never did. One single O(n) UPDATE pass.
    execute("""
    WITH ordered AS (
      SELECT id, row_number() OVER (ORDER BY inserted_at ASC, id ASC) AS rn
        FROM agent_logs
    )
    UPDATE agent_logs AS a
       SET seq_no = o.rn
      FROM ordered AS o
     WHERE a.id = o.id
    """)

    # Owned sequence wired as the column default, starting just after the backfilled max
    # so new inserts continue the monotonic run.
    execute("CREATE SEQUENCE agent_logs_seq_no_seq OWNED BY agent_logs.seq_no")

    execute(
      "SELECT setval('agent_logs_seq_no_seq', COALESCE((SELECT MAX(seq_no) FROM agent_logs), 0) + 1, false)"
    )

    execute(
      "ALTER TABLE agent_logs ALTER COLUMN seq_no SET DEFAULT nextval('agent_logs_seq_no_seq')"
    )

    execute("ALTER TABLE agent_logs ALTER COLUMN seq_no SET NOT NULL")

    create unique_index(:agent_logs, [:seq_no])
  end

  def down do
    drop unique_index(:agent_logs, [:seq_no])

    alter table(:agent_logs) do
      remove :seq_no
    end

    # The `OWNED BY` sequence drops with the column on most adapters; drop explicitly to
    # be safe across environments.
    execute("DROP SEQUENCE IF EXISTS agent_logs_seq_no_seq")
  end
end
