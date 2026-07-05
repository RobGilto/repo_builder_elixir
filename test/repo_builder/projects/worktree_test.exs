defmodule RepoBuilder.Projects.WorktreeTest do
  @moduledoc """
  Worktree isolation against a throwaway git fixture: creation, branch naming, run
  isolation (distinct trees), idempotent cleanup, and the non-git direct fallthrough.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Projects.Worktree

  setup do
    base = Path.join(System.tmp_dir!(), "rb_wt_#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    scratch = Path.join(base, "scratch")
    File.mkdir_p!(repo)

    # Initialise a real git repo with one commit so `worktree add` has a base ref.
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "hello")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: repo)

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, repo: repo, scratch: scratch}
  end

  test "checkout creates a worktree on a branch named for the run", %{
    repo: repo,
    scratch: scratch
  } do
    assert {:ok, info} = Worktree.checkout(repo, run_id: "run-1", scratch_base: scratch)
    assert info.branch == "adw/run-1"
    assert File.dir?(info.path)
    assert info.path == Path.join(scratch, "run-1")

    {branches, 0} = System.cmd("git", ["branch", "--list", "adw/run-1"], cd: repo)
    assert branches =~ "adw/run-1"
  end

  test "two runs get distinct, isolated trees", %{repo: repo, scratch: scratch} do
    assert {:ok, a} = Worktree.checkout(repo, run_id: "a", scratch_base: scratch)
    assert {:ok, b} = Worktree.checkout(repo, run_id: "b", scratch_base: scratch)
    assert a.path != b.path
    assert File.dir?(a.path) and File.dir?(b.path)
  end

  test "checkout is idempotent for the same run", %{repo: repo, scratch: scratch} do
    assert {:ok, first} = Worktree.checkout(repo, run_id: "dup", scratch_base: scratch)
    assert {:ok, second} = Worktree.checkout(repo, run_id: "dup", scratch_base: scratch)
    assert first.path == second.path
  end

  test "cleanup removes the tree and is idempotent", %{repo: repo, scratch: scratch} do
    assert {:ok, info} = Worktree.checkout(repo, run_id: "rm", scratch_base: scratch)
    assert File.dir?(info.path)

    assert :ok = Worktree.cleanup(info)
    refute File.dir?(info.path)
    # Second cleanup tolerates the already-removed tree.
    assert :ok = Worktree.cleanup(info)
  end

  describe "cleanup/1 safety commit" do
    test "commits uncommitted (tracked + untracked) work to the branch before removing", %{
      repo: repo,
      scratch: scratch
    } do
      assert {:ok, info} = Worktree.checkout(repo, run_id: "dirty", scratch_base: scratch)

      # A tracked modification and a brand-new untracked file — neither committed.
      File.write!(Path.join(info.path, "README.md"), "hours of work")
      File.write!(Path.join(info.path, "new_work.txt"), "do not lose me")

      assert :ok = Worktree.cleanup(info)
      refute File.dir?(info.path)

      # The branch survived AND carries a safety commit with both files.
      {log, 0} = System.cmd("git", ["log", "--oneline", "adw/dirty"], cd: repo)
      assert log =~ "safety commit on session teardown"

      {shown, 0} = System.cmd("git", ["show", "adw/dirty:new_work.txt"], cd: repo)
      assert shown =~ "do not lose me"

      {readme, 0} = System.cmd("git", ["show", "adw/dirty:README.md"], cd: repo)
      assert readme =~ "hours of work"
    end

    test "a clean tree is removed without adding a commit", %{repo: repo, scratch: scratch} do
      assert {:ok, info} = Worktree.checkout(repo, run_id: "clean", scratch_base: scratch)

      {base_sha, 0} = System.cmd("git", ["rev-parse", "main"], cd: repo)
      assert :ok = Worktree.cleanup(info)
      refute File.dir?(info.path)

      # No safety commit: the branch still points exactly at its base.
      {branch_sha, 0} = System.cmd("git", ["rev-parse", "adw/clean"], cd: repo)
      assert String.trim(branch_sha) == String.trim(base_sha)
    end

    test "is idempotent — a second cleanup tolerates the already-removed tree", %{
      repo: repo,
      scratch: scratch
    } do
      assert {:ok, info} = Worktree.checkout(repo, run_id: "idem", scratch_base: scratch)
      File.write!(Path.join(info.path, "wip.txt"), "x")

      assert :ok = Worktree.cleanup(info)
      assert :ok = Worktree.cleanup(info)
    end
  end

  describe "checkout/2 takeover — re-attach a kept branch" do
    test "re-attaches to the branch (with its commits) after the dir was removed", %{
      repo: repo,
      scratch: scratch
    } do
      assert {:ok, first} = Worktree.checkout(repo, run_id: "takeover", scratch_base: scratch)

      # A prior worker commits work on the branch, then its session tears the tree down.
      File.write!(Path.join(first.path, "prior_work.txt"), "prior worker output")
      {_, 0} = System.cmd("git", ["add", "."], cd: first.path)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "prior work"], cd: first.path)
      :ok = Worktree.cleanup(first)
      refute File.dir?(first.path)

      # A fresh worker takes over the SAME run id: re-attaches, same branch, commit intact.
      assert {:ok, second} = Worktree.checkout(repo, run_id: "takeover", scratch_base: scratch)
      assert second.branch == "adw/takeover"
      assert File.dir?(second.path)
      assert File.read!(Path.join(second.path, "prior_work.txt")) == "prior worker output"
    end

    test "a fresh run id still creates a new branch off the base", %{
      repo: repo,
      scratch: scratch
    } do
      assert {:ok, info} = Worktree.checkout(repo, run_id: "brand-new", scratch_base: scratch)
      assert info.branch == "adw/brand-new"

      # New branch points at the base (main), no inherited history beyond it.
      {base_sha, 0} = System.cmd("git", ["rev-parse", "main"], cd: repo)
      {branch_sha, 0} = System.cmd("git", ["rev-parse", "adw/brand-new"], cd: repo)
      assert String.trim(branch_sha) == String.trim(base_sha)
    end
  end

  test "a non-git directory falls through to direct cwd" do
    plain = Path.join(System.tmp_dir!(), "rb_wt_plain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf(plain) end)

    assert {:direct, ^plain} = Worktree.checkout(plain, run_id: "x")
    refute Worktree.git_repo?(plain)
  end

  describe "list/1" do
    test "returns the main tree plus provisioned worktrees with branches", %{
      repo: repo,
      scratch: scratch
    } do
      {:ok, info} = Worktree.checkout(repo, run_id: "lst", scratch_base: scratch)

      assert {:ok, [main | rest]} = Worktree.list(repo)
      # Symlinked tmp dirs (macOS /var → /private/var) make exact path equality fragile;
      # compare expanded basenames instead.
      assert Path.basename(main.path) == Path.basename(repo)
      assert main.branch == "main"

      entry = Enum.find(rest, &(&1.branch == "adw/lst"))
      assert %{path: path, head_sha: sha} = entry
      assert Path.basename(path) == Path.basename(info.path)
      assert is_binary(sha)
    end

    test "a detached worktree carries branch: nil", %{repo: repo, scratch: scratch} do
      detached = Path.join(scratch, "detached")
      File.mkdir_p!(scratch)
      {_, 0} = System.cmd("git", ["worktree", "add", "--detach", detached], cd: repo)

      assert {:ok, entries} = Worktree.list(repo)
      entry = Enum.find(entries, &(Path.basename(&1.path) == "detached"))
      assert entry.branch == nil
      assert is_binary(entry.head_sha)
    end

    test "a non-git directory errors" do
      plain = Path.join(System.tmp_dir!(), "rb_wt_ls_#{System.unique_integer([:positive])}")
      File.mkdir_p!(plain)
      on_exit(fn -> File.rm_rf(plain) end)

      assert {:error, :not_a_git_repo} = Worktree.list(plain)
    end
  end

  describe "ahead_behind/3 and diff_shortstat/3" do
    test "zero ahead/behind and empty shortstat for an untouched branch", %{
      repo: repo,
      scratch: scratch
    } do
      {:ok, _info} = Worktree.checkout(repo, run_id: "same", scratch_base: scratch)

      assert {:ok, {0, 0}} = Worktree.ahead_behind(repo, "main", "adw/same")
      assert {:ok, ""} = Worktree.diff_shortstat(repo, "main", "adw/same")
    end

    test "counts commits ahead and reports the diff stat", %{repo: repo, scratch: scratch} do
      {:ok, info} = Worktree.checkout(repo, run_id: "ahead", scratch_base: scratch)
      File.write!(Path.join(info.path, "new.txt"), "work\n")
      {_, 0} = System.cmd("git", ["add", "."], cd: info.path)
      {_, 0} = System.cmd("git", ["commit", "-q", "-m", "wt work"], cd: info.path)

      assert {:ok, {1, 0}} = Worktree.ahead_behind(repo, "main", "adw/ahead")
      assert {:ok, stat} = Worktree.diff_shortstat(repo, "main", "adw/ahead")
      assert stat =~ "1 file changed"
    end

    test "a missing branch errors, never raises", %{repo: repo} do
      assert {:error, _reason} = Worktree.ahead_behind(repo, "main", "adw/ghost")
      assert {:error, _reason} = Worktree.diff_shortstat(repo, "main", "adw/ghost")
    end
  end

  describe "delete_branch/2 and prune/1" do
    test "deletes an adw/ branch after its worktree is removed", %{
      repo: repo,
      scratch: scratch
    } do
      {:ok, info} = Worktree.checkout(repo, run_id: "del", scratch_base: scratch)
      :ok = Worktree.cleanup(info)

      assert :ok = Worktree.delete_branch(repo, "adw/del")
      {branches, 0} = System.cmd("git", ["branch", "--list", "adw/del"], cd: repo)
      assert String.trim(branches) == ""
    end

    test "refuses any branch outside the adw/ prefix", %{repo: repo} do
      assert {:error, :not_an_adw_branch} = Worktree.delete_branch(repo, "main")
      assert {:error, :not_an_adw_branch} = Worktree.delete_branch(repo, "dev")
    end

    test "prune reclaims a hand-deleted worktree's registration", %{
      repo: repo,
      scratch: scratch
    } do
      {:ok, info} = Worktree.checkout(repo, run_id: "pr", scratch_base: scratch)
      File.rm_rf!(info.path)

      assert :ok = Worktree.prune(repo)
      {:ok, entries} = Worktree.list(repo)
      refute Enum.any?(entries, &(&1.branch == "adw/pr"))
    end
  end

  test "scratch_base/0 resolves the configured (or tmp fallback) parent dir" do
    assert base = Worktree.scratch_base()
    assert is_binary(base)
    assert String.ends_with?(base, "rb_worktrees") or File.dir?(Path.dirname(base))
  end
end
