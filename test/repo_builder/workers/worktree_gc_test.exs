defmodule RepoBuilder.Workers.WorktreeGCTest do
  @moduledoc """
  The nightly worktree sweep (worktree-panel-and-gc plan): reclaims exactly the
  merged-and-aged worktrees, never the young or unmerged, is idempotent across runs,
  and honours the `gc_enabled: false` kill switch.
  """
  use RepoBuilder.DataCase, async: false
  use Oban.Testing, repo: RepoBuilder.Repo

  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Worktree
  alias RepoBuilder.Workers.WorktreeGC
  alias RepoBuilder.Workflows

  defp uniq, do: System.unique_integer([:positive])

  defp git!(repo, args) do
    {out, code} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    if code != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  setup do
    base = Path.join(System.tmp_dir!(), "rb_gc_#{uniq()}")
    repo = Path.join(base, "repo")
    scratch = Path.join(base, "scratch")
    File.mkdir_p!(repo)
    File.mkdir_p!(scratch)

    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "README.md"), "hello\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])

    previous = Application.get_env(:repo_builder, :worktree, [])
    Application.put_env(:repo_builder, :worktree, Keyword.put(previous, :scratch_base, scratch))

    on_exit(fn ->
      Application.put_env(:repo_builder, :worktree, previous)
      File.rm_rf(base)
    end)

    {:ok, project} = Projects.create_project(%{name: "gc-#{uniq()}", root_path: repo})
    {:ok, project: project}
  end

  defp seed_run(project, run_id, attrs) do
    {:ok, info} = Worktree.checkout(project.root_path, run_id: run_id)

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "wf-#{uniq()}",
        type: "plan_build",
        steps: [%{"name" => "plan", "harness" => "fake", "on_success" => "done"}]
      })

    {:ok, run} =
      Workflows.create_run(
        Map.merge(
          %{
            workflow_id: wf.id,
            status: :succeeded,
            project_id: project.id,
            worktree_path: info.path,
            worktree_branch: info.branch
          },
          attrs
        )
      )

    {run, info}
  end

  defp backdate!(run, days) do
    at = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    {1, _} =
      Repo.update_all(
        from(r in Workflows.WorkflowRun, where: r.id == ^run.id),
        set: [inserted_at: at]
      )

    :ok
  end

  test "reclaims exactly the merged-and-aged worktree; idempotent", %{project: project} do
    {old_run, old_info} = seed_run(project, "old", %{merge_status: :merged, merged_sha: "abc"})
    backdate!(old_run, 30)
    {_young_run, young_info} = seed_run(project, "young", %{merge_status: :merged})
    {unmerged_run, unmerged_info} = seed_run(project, "unmerged", %{})
    backdate!(unmerged_run, 30)

    assert :ok = perform_job(WorktreeGC, %{})
    refute File.dir?(old_info.path)
    assert File.dir?(young_info.path)
    assert File.dir?(unmerged_info.path)

    # The reclaimed branch is gone too (commits already on the trunk).
    branches = git!(project.root_path, ["branch", "--list", old_info.branch])
    assert String.trim(branches) == ""

    # Idempotent: a second sweep finds nothing physical left to reclaim.
    assert WorktreeGC.sweep() == 0
  end

  test "gc_enabled: false is a no-op kill switch", %{project: project} do
    {old_run, old_info} = seed_run(project, "kept", %{merge_status: :merged})
    backdate!(old_run, 30)

    config = Application.get_env(:repo_builder, :worktree, [])
    Application.put_env(:repo_builder, :worktree, Keyword.put(config, :gc_enabled, false))
    on_exit(fn -> Application.put_env(:repo_builder, :worktree, config) end)

    assert :ok = perform_job(WorktreeGC, %{})
    assert File.dir?(old_info.path)
  end

  test "a project with a non-git root_path is skipped, not fatal" do
    plain = Path.join(System.tmp_dir!(), "rb_gc_plain_#{uniq()}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf(plain) end)
    {:ok, _project} = Projects.create_project(%{name: "plain-#{uniq()}", root_path: plain})

    assert WorktreeGC.sweep() == 0
  end
end
