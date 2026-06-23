defmodule RepoBuilder.Session.WorktreeSessionTest do
  @moduledoc """
  Worktree isolation wired through the session runtime (Phase 4): a `:worktree`-mode
  session on a git repo runs in a provisioned worktree and removes it on exit (the
  reviewable branch survives); a non-git cwd falls through to the direct path without
  regression.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Session.Supervisor

  defp unique_agent, do: "agent-" <> Integer.to_string(System.unique_integer([:positive]))

  defp git_repo do
    base = Path.join(System.tmp_dir!(), "rb_wts_#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: repo)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: repo)
    File.write!(Path.join(repo, "README.md"), "hi")
    {_, 0} = System.cmd("git", ["add", "."], cd: repo)
    {_, 0} = System.cmd("git", ["commit", "-q", "-m", "init"], cd: repo)
    on_exit(fn -> File.rm_rf(base) end)
    {base, repo}
  end

  setup do
    original = Application.get_env(:repo_builder, :worktree)
    on_exit(fn -> Application.put_env(:repo_builder, :worktree, original) end)
    :ok
  end

  test "a :worktree-mode session runs in a worktree and leaves the branch behind" do
    {base, repo} = git_repo()
    scratch = Path.join(base, "scratch")
    Application.put_env(:repo_builder, :worktree, scratch_base: scratch)

    agent = unique_agent()
    subscribe(agent)

    {:ok, pid} =
      Supervisor.start_session(
        agent_id: agent,
        harness: "fake",
        prompt: "hi",
        cwd: repo,
        isolation_mode: :worktree,
        run_id: "wt-run"
      )

    ref = Process.monitor(pid)
    assert_receive {:harness_event, %Event.Done{ok: true}}, 2_000
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    # Worktree removed on exit, but the reviewable branch survives for the PR handoff.
    refute File.dir?(Path.join(scratch, "wt-run"))
    {branches, 0} = System.cmd("git", ["branch", "--list", "adw/wt-run"], cd: repo)
    assert branches =~ "adw/wt-run"
  end

  test "a non-git cwd with :worktree mode falls through to the direct path" do
    plain = Path.join(System.tmp_dir!(), "rb_wts_plain_#{System.unique_integer([:positive])}")
    File.mkdir_p!(plain)
    on_exit(fn -> File.rm_rf(plain) end)

    agent = unique_agent()
    subscribe(agent)

    {:ok, pid} =
      Supervisor.start_session(
        agent_id: agent,
        harness: "fake",
        prompt: "hi",
        cwd: plain,
        isolation_mode: :worktree,
        run_id: "x"
      )

    ref = Process.monitor(pid)
    assert_receive {:harness_event, %Event.Done{ok: true}}, 2_000
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
    # Operator dir preserved (direct path: never deleted).
    assert File.dir?(plain)
  end
end
