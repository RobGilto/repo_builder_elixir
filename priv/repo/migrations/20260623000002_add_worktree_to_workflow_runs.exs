defmodule RepoBuilder.Repo.Migrations.AddWorktreeToWorkflowRuns do
  use Ecto.Migration

  @moduledoc """
  Record the git worktree a run was isolated in (agentic-layer adaptor, Phase 4), so the
  UI can surface the reviewable branch for a PR/merge handoff. Both nullable: a
  `:direct`-isolation run (the default) records neither.
  """

  def change do
    alter table(:workflow_runs) do
      add :worktree_path, :string
      add :worktree_branch, :string
    end
  end
end
