defmodule RepoBuilder.Projects.WorktreeInventoryTest do
  @moduledoc """
  The reconciling worktree inventory against REAL tmp git fixtures + DB run rows:
  union of run rows / git registry / scratch dir (with orphans in both directions),
  on-demand merge recording `:merged`/`:failed`, remove's unmerged-work guard, and
  the gc sweep's merged-and-aged eligibility.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Projects
  alias RepoBuilder.Projects.Worktree
  alias RepoBuilder.Projects.WorktreeInventory
  alias RepoBuilder.Projects.WorktreeInventory.Entry
  alias RepoBuilder.Repo
  alias RepoBuilder.Workflows

  # async: false — the scratch base is process-global app env.

  setup do
    base = Path.join(System.tmp_dir!(), "rb_inv_#{System.unique_integer([:positive])}")
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

    {:ok, project} = Projects.create_project(%{name: "inv-#{uniq()}", root_path: repo})
    {:ok, project: project, repo: repo, scratch: scratch}
  end

  defp uniq, do: System.unique_integer([:positive])

  defp git!(repo, args) do
    {out, code} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    if code != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  defp workflow_run(project, attrs) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "wf-#{uniq()}",
        type: "plan_build",
        steps: [%{"name" => "plan", "harness" => "fake", "on_success" => "done"}]
      })

    {:ok, run} =
      Workflows.create_run(
        Map.merge(%{workflow_id: wf.id, status: :succeeded, project_id: project.id}, attrs)
      )

    run
  end

  # A run row backed by a REAL provisioned worktree.
  defp provisioned_run(project, run_id, extra \\ %{}) do
    {:ok, info} = Worktree.checkout(project.root_path, run_id: run_id)

    run =
      workflow_run(
        project,
        Map.merge(%{worktree_path: info.path, worktree_branch: info.branch}, extra)
      )

    {run, info}
  end

  defp commit_in!(path, file) do
    File.write!(Path.join(path, file), "work\n")
    git!(path, ["add", "."])
    git!(path, ["commit", "-q", "-m", "wt work"])
  end

  describe "list/1" do
    test "reconciles run rows, git registry, and scratch dir", %{project: project} do
      {run, info} = provisioned_run(project, "r1")

      assert {:ok, [entry]} = WorktreeInventory.list(project)
      assert %Entry{} = entry
      assert entry.branch == info.branch
      assert entry.run_id == run.id
      assert entry.on_disk?
      assert entry.in_git?
      assert entry.ahead == 0
      assert entry.behind == 0
      assert entry.shortstat == ""
    end

    test "a git-registered worktree with no run row appears as an orphan", %{project: project} do
      {:ok, info} = Worktree.checkout(project.root_path, run_id: "ghost")

      assert {:ok, [entry]} = WorktreeInventory.list(project)
      assert entry.branch == info.branch
      assert entry.run_id == nil
      assert entry.in_git?
      assert entry.on_disk?
    end

    test "a run row whose worktree was hand-deleted shows missing-on-disk", %{project: project} do
      {_run, info} = provisioned_run(project, "gone")
      File.rm_rf!(info.path)
      :ok = Worktree.prune(project.root_path)

      assert {:ok, [entry]} = WorktreeInventory.list(project)
      refute entry.on_disk?
      refute entry.in_git?
      assert entry.branch == info.branch
    end

    test "a foreign scratch dir (different repo) is not attributed to this project", %{
      project: project,
      scratch: scratch
    } do
      foreign = Path.join(scratch, "foreign")
      File.mkdir_p!(foreign)
      File.write!(Path.join(foreign, ".git"), "gitdir: /somewhere/else/.git/worktrees/foreign\n")

      assert {:ok, []} = WorktreeInventory.list(project)
    end

    test "counts commits ahead on an enriched entry", %{project: project} do
      {_run, info} = provisioned_run(project, "ahead")
      commit_in!(info.path, "new.txt")

      assert {:ok, [entry]} = WorktreeInventory.list(project)
      assert entry.ahead == 1
      assert entry.shortstat =~ "1 file changed"
    end
  end

  describe "merge/2" do
    test "lands the branch on the trunk and records :merged on the run", %{project: project} do
      {run, info} = provisioned_run(project, "land", %{merge_status: nil})
      commit_in!(info.path, "feature.txt")

      assert {:ok, %{sha: sha, trunk: "main"}} = WorktreeInventory.merge(project, info.branch)
      assert is_binary(sha)

      reloaded = Repo.reload!(run)
      assert reloaded.merge_status == :merged
      assert reloaded.merged_sha == sha
    end

    test "a conflict records :failed with the git error", %{project: project} do
      {run, info} = provisioned_run(project, "clash")
      # Conflicting edits to the same file on trunk and branch.
      File.write!(Path.join(info.path, "README.md"), "branch side\n")
      git!(info.path, ["commit", "-aqm", "branch edit"])
      File.write!(Path.join(project.root_path, "README.md"), "trunk side\n")
      git!(project.root_path, ["commit", "-aqm", "trunk edit"])

      assert {:error, _reason} = WorktreeInventory.merge(project, info.branch)

      reloaded = Repo.reload!(run)
      assert reloaded.merge_status == :failed
      assert is_binary(reloaded.merge_error)
    end
  end

  describe "remove/3" do
    test "refuses an unmerged entry with commits ahead unless forced", %{project: project} do
      {_run, info} = provisioned_run(project, "keep")
      commit_in!(info.path, "unlanded.txt")
      {:ok, [entry]} = WorktreeInventory.list(project)

      assert {:error, :unmerged} = WorktreeInventory.remove(project, entry)
      assert File.dir?(entry.path)

      assert :ok = WorktreeInventory.remove(project, entry, force: true)
      refute File.dir?(entry.path)
    end

    test "removes a no-work worktree and optionally its branch", %{project: project} do
      {_run, _info} = provisioned_run(project, "clean")
      {:ok, [entry]} = WorktreeInventory.list(project)

      assert :ok = WorktreeInventory.remove(project, entry, delete_branch: true)
      refute File.dir?(entry.path)
      branches = git!(project.root_path, ["branch", "--list", entry.branch])
      assert String.trim(branches) == ""
    end
  end

  describe "gc/2" do
    test "reclaims only merged entries older than the cutoff", %{project: project} do
      # Old + merged ⇒ eligible.
      {old_run, old_info} = provisioned_run(project, "old", %{merge_status: :merged})
      backdate!(old_run, -30)
      # Fresh + merged ⇒ too young.
      {_young_run, young_info} = provisioned_run(project, "young", %{merge_status: :merged})
      # Old + unmerged ⇒ never GC'd.
      {unmerged_run, unmerged_info} = provisioned_run(project, "unmerged")
      commit_in!(unmerged_info.path, "keepme.txt")
      backdate!(unmerged_run, -30)

      assert {:ok, 1} = WorktreeInventory.gc(project, days: 7)
      refute File.dir?(old_info.path)
      assert File.dir?(young_info.path)
      assert File.dir?(unmerged_info.path)

      # Idempotent: nothing left to reclaim.
      assert {:ok, 0} = WorktreeInventory.gc(project, days: 7)
    end
  end

  defp backdate!(run, days) do
    at = DateTime.add(DateTime.utc_now(), days * 86_400, :second)

    {1, _} =
      Repo.update_all(
        from(r in RepoBuilder.Workflows.WorkflowRun, where: r.id == ^run.id),
        set: [inserted_at: at]
      )

    :ok
  end
end
