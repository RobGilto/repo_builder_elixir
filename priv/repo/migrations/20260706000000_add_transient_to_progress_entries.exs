defmodule RepoBuilder.Repo.Migrations.AddTransientToProgressEntries do
  use Ecto.Migration

  @moduledoc """
  Represent transient provider failures on Progress entries (issue rate-limit-stall).

  A turn that dies on a transient provider condition (rate limit / overload) is
  auto-recorded with `transient: true` so the drive-loop failure ladder can treat it
  as ladder-neutral (neither progress nor stall) instead of counting it toward the
  replan/escalate budget. Additive; defaults keep every existing entry unchanged.
  """

  def change do
    alter table(:progress_entries) do
      add :transient, :boolean, null: false, default: false
    end
  end
end
