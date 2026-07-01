defmodule RepoBuilder.Repo.Migrations.AddUiUxToWorkstreamPhases do
  use Ecto.Migration

  @moduledoc """
  Iterative UI/UX polish phase (orchestrator-iterative-ui-ux-polish-phase).

  A phase gains a `kind` (`backend` | `ui_ux`), an optional `surface`
  (`web` | `desktop` | `tui`), and an `iteration` counter for the bounded UI/UX
  review→fix loop. Defaults keep every existing (`backend`) phase byte-for-byte
  unchanged. Additive and reversible.
  """

  def change do
    alter table(:orchestrator_workstream_phases) do
      add :kind, :string, null: false, default: "backend"
      add :surface, :string
      add :iteration, :integer, null: false, default: 0
    end
  end
end
