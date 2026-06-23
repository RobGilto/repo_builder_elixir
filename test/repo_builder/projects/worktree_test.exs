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

  test "a non-git directory falls through to direct cwd" do
    plain = Path.join(System.tmp_dir!(), "rb_wt_plain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf(plain) end)

    assert {:direct, ^plain} = Worktree.checkout(plain, run_id: "x")
    refute Worktree.git_repo?(plain)
  end
end
