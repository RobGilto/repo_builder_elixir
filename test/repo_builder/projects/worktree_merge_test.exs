defmodule RepoBuilder.Projects.WorktreeMergeTest do
  @moduledoc """
  Unit tests for `Worktree.detect_trunk/1` and `Worktree.merge/2`
  (issue-adw-non-iso-merge) against REAL temp git repo fixtures — dynamic trunk
  detection (never the hardcoded literal `main`), successful merge, conflict/failure
  restoration, and the no-remote-vs-remote behavior split.
  """
  use ExUnit.Case, async: true

  alias RepoBuilder.Projects.Worktree

  defp init_repo(trunk) do
    base = Path.join(System.tmp_dir!(), "rb_wt_merge_#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", trunk])
    git!(repo, ["config", "user.email", "t@example.com"])
    git!(repo, ["config", "user.name", "t"])
    File.write!(Path.join(repo, "README.md"), "hi\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "init"])
    on_exit(fn -> File.rm_rf(base) end)
    {base, repo}
  end

  # A bare "origin" plus a fetched origin/HEAD symbolic ref, so detection exercises
  # the remote-preferred precedence path.
  defp add_origin(base, repo, trunk) do
    bare = Path.join(base, "origin.git")
    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", trunk, bare])
    git!(repo, ["remote", "add", "origin", bare])
    git!(repo, ["push", "-q", "-u", "origin", trunk])
    git!(repo, ["remote", "set-head", "origin", "--auto"])
    bare
  end

  defp branch_with_commit(repo, branch, file, content) do
    git!(repo, ["checkout", "-q", "-b", branch])
    File.write!(Path.join(repo, file), content)
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-q", "-m", "work on #{branch}"])
  end

  defp git!(repo, args) do
    {out, code} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    if code != 0, do: flunk("git #{Enum.join(args, " ")} failed: #{out}")
    out
  end

  describe "detect_trunk/1" do
    test "prefers origin/HEAD symbolic ref over the checked-out branch" do
      {base, repo} = init_repo("dev")
      add_origin(base, repo, "dev")
      # Move off trunk — detection must still say dev, not the current branch.
      branch_with_commit(repo, "feature/x", "x.txt", "x\n")

      assert {:ok, "dev"} = Worktree.detect_trunk(repo)
    end

    test "falls back to the current branch when there is no origin remote" do
      {_base, repo} = init_repo("trunk-of-truth")
      assert {:ok, "trunk-of-truth"} = Worktree.detect_trunk(repo)
    end

    test "a non-git directory is an error" do
      dir = Path.join(System.tmp_dir!(), "rb_not_git_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:error, :not_a_git_repo} = Worktree.detect_trunk(dir)
    end
  end

  describe "merge/2" do
    test "merges a branch into a dev trunk locally (no remote) and reports the sha" do
      {_base, repo} = init_repo("dev")
      branch_with_commit(repo, "adw/run1", "work.txt", "done\n")
      git!(repo, ["checkout", "-q", "dev"])

      assert {:ok, %{sha: sha, trunk: "dev"}} = Worktree.merge(repo, branch: "adw/run1")
      assert sha =~ ~r/^[0-9a-f]{40}$/
      # The work landed on dev.
      assert File.exists?(Path.join(repo, "work.txt"))
      assert git!(repo, ["branch", "--show-current"]) =~ "dev"
    end

    test "pushes the merged trunk when an origin remote exists" do
      {base, repo} = init_repo("dev")
      bare = add_origin(base, repo, "dev")
      branch_with_commit(repo, "adw/run2", "pushed.txt", "p\n")

      assert {:ok, %{sha: sha}} = Worktree.merge(repo, branch: "adw/run2")

      {out, 0} = System.cmd("git", ["rev-parse", "dev"], cd: bare)
      assert String.trim(out) == sha
    end

    test "a conflict aborts, restores the original branch, and returns an error" do
      {_base, repo} = init_repo("dev")
      branch_with_commit(repo, "adw/run3", "conflict.txt", "branch side\n")
      git!(repo, ["checkout", "-q", "dev"])
      File.write!(Path.join(repo, "conflict.txt"), "trunk side\n")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "-q", "-m", "trunk conflict"])
      # Run the merge from a third branch to prove restoration.
      git!(repo, ["checkout", "-q", "-b", "observer"])

      assert {:error, reason} = Worktree.merge(repo, branch: "adw/run3")
      assert reason =~ "conflict" or reason =~ "CONFLICT"
      assert String.trim(git!(repo, ["branch", "--show-current"])) == "observer"
      # No mid-merge state left behind.
      refute File.exists?(Path.join(repo, ".git/MERGE_HEAD"))
    end

    test "a branch with zero commits ahead of trunk still succeeds (no-op merge)" do
      {_base, repo} = init_repo("dev")
      git!(repo, ["branch", "adw/run4"])

      assert {:ok, %{trunk: "dev"}} = Worktree.merge(repo, branch: "adw/run4")
    end
  end
end
