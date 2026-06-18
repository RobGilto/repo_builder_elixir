defmodule RepoBuilder.Repo.Migrations.AddProviderModelToAgentLogs do
  use Ecto.Migration

  @moduledoc """
  Snapshot `provider`/`model` onto every `agent_logs` row at persist time so cost can
  be grouped by `(harness, provider, model)` with a time-stable `GROUP BY` rather than
  a fragile join to the owner's *current* identity (which mutates via
  `set_model`/`set_provider`). Both columns are nullable — a row written before this
  feature, or by a path that has no model, groups into a clearly-labelled "unknown"
  dimension instead of crashing the rollup.
  """

  def up do
    alter table(:agent_logs) do
      add :provider, :string
      add :model, :string
    end

    # Keeps the rollup's `GROUP BY harness, provider, model` fast.
    create index(:agent_logs, [:harness, :provider, :model])

    # Best-effort backfill of pre-existing rows from the owner's CURRENT identity
    # (approximate for historical rows; exact for rows written after this migration).
    # No-op when the owner tables are empty.
    execute("""
    UPDATE agent_logs AS l
       SET provider = a.provider::text,
           model    = a.model
      FROM agents AS a
     WHERE l.agent_id = a.id
       AND l.model IS NULL
    """)

    execute("""
    UPDATE agent_logs AS l
       SET provider = o.provider,
           model    = o.model
      FROM orchestrators AS o
     WHERE l.orchestrator_id = o.id
       AND l.model IS NULL
    """)
  end

  def down do
    drop index(:agent_logs, [:harness, :provider, :model])

    alter table(:agent_logs) do
      remove :provider
      remove :model
    end
  end
end
