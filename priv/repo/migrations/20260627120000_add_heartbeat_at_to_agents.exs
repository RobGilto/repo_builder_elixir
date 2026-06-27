defmodule RepoBuilder.Repo.Migrations.AddHeartbeatAtToAgents do
  use Ecto.Migration

  @moduledoc """
  Liveness heartbeat for workers (self-healing orchestrator, Phase 1). `heartbeat_at`
  is bumped on every NORMALIZED harness event for a worker (real progress) — distinct
  from `updated_at` (any row write). It drives the soft quiescence demotion
  (`:running → :idle`, alive) in `Session.Server` and the `LivenessReaper`'s live-stale
  idle-demotion pass. Backfilled to `updated_at` so existing rows have a sane baseline;
  indexed for the staleness query.
  """

  def change do
    alter table(:agents) do
      add :heartbeat_at, :utc_datetime_usec
    end

    # Backfill existing rows so the staleness query has a baseline (down is a no-op; the
    # column drop on rollback reverses the column itself).
    execute("UPDATE agents SET heartbeat_at = updated_at", "SELECT 1")

    create index(:agents, [:heartbeat_at])
  end
end
