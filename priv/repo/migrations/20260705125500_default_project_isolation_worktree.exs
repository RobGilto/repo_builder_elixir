defmodule RepoBuilder.Repo.Migrations.DefaultProjectIsolationWorktree do
  use Ecto.Migration

  @moduledoc """
  Flip the `projects.isolation_mode` COLUMN DEFAULT from 'direct' to 'worktree'
  (worktree-panel-and-gc plan). Existing rows are deliberately untouched — a stored
  :direct is an explicit operator choice, flippable from the projects UI toggle.
  """

  def up do
    alter table(:projects) do
      modify :isolation_mode, :string, default: "worktree"
    end
  end

  def down do
    alter table(:projects) do
      modify :isolation_mode, :string, default: "direct"
    end
  end
end
