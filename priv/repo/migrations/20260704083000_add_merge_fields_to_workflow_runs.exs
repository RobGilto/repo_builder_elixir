defmodule RepoBuilder.Repo.Migrations.AddMergeFieldsToWorkflowRuns do
  use Ecto.Migration

  @moduledoc """
  issue-adw-non-iso-merge: the terminal `merge` step's outcome per run. `merge_status`
  is `NULL` for runs without a merge step (direct-mode / pre-feature), else
  `merged | failed`. `merged_sha` is the trunk HEAD after a successful merge;
  `merge_error` carries the git failure output for a failed one.
  """

  def change do
    alter table(:workflow_runs) do
      add :merge_status, :string
      add :merged_sha, :string
      add :merge_error, :text
    end
  end
end
