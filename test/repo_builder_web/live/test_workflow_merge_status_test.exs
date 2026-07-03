defmodule RepoBuilderWeb.TestWorkflowMergeStatusTest do
  @moduledoc """
  LiveView integration for issue-adw-non-iso-merge: a completed worktree-isolated run's
  merge outcome (`merge_status`/`merged_sha` on `workflow_runs`) renders on the project
  dashboard's Recent-runs list — "merged @ <short-sha>" for a landed run, "merge failed"
  for a conflicted one, "unmerged" for a pre-feature/branch-only run.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Projects, WorkflowEngine, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  defp project_fixture do
    root = Path.join(System.tmp_dir!(), "rb_merge_status_#{uniq()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "mix.exs"), "defmodule X.MixProject do end")
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, project} =
      Projects.create_project(%{"name" => "merge-ui-#{uniq()}", "root_path" => root})

    project
  end

  defp run_fixture(project, merge_attrs) do
    {:ok, wf} = WorkflowEngine.create_workflow_of_type("merge-ui-wf-#{uniq()}", "plan_build")
    {:ok, run} = Workflows.create_run(%{workflow_id: wf.id, project_id: project.id})

    {:ok, run} =
      Workflows.update_run(run, %{
        status: :succeeded,
        worktree_path: "/tmp/x",
        worktree_branch: "adw/#{run.id}"
      })

    case merge_attrs do
      nil -> run
      attrs -> with {:ok, updated} <- Workflows.record_merge(run, attrs), do: updated
    end
  end

  test "a merged run renders its short sha; failed and unmerged runs render their states", %{
    conn: conn
  } do
    project = project_fixture()
    sha = String.duplicate("a1b2c3d", 6) |> String.slice(0, 40)
    _merged = run_fixture(project, %{merge_status: :merged, merged_sha: sha})
    _failed = run_fixture(project, %{merge_status: :failed, merge_error: "CONFLICT: x.txt"})
    _unmerged = run_fixture(project, nil)

    {:ok, _view, html} = live(conn, ~p"/projects/#{project.id}")

    assert html =~ "merged @ #{String.slice(sha, 0, 7)}"
    assert html =~ "merge failed"
    assert html =~ "unmerged"
  end
end
