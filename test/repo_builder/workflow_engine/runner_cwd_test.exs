defmodule RepoBuilder.WorkflowEngine.RunnerCwdTest do
  @moduledoc """
  Regression for the planning-wizard target-repo launch bug: the `Runner` must thread
  the launch `cwd`/`isolation_mode` from `start_workflow/2` into each step session, so the
  work runs IN the target repo (not an ephemeral managed scratch workspace).

  Observable proof: with `isolation_mode: :worktree` on a git fixture, the step session
  provisions the deterministic `adw/<run_id>` branch in that repo (it survives the
  worktree's git-aware cleanup). With no `cwd`, no branch is created in the repo (the
  cwd-less path is unchanged — managed scratch workspace).

  `async: false` (shared sandbox reaches the spawned Runner + session).
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{WorkflowEngine, Workflows}

  defp git_repo do
    base = Path.join(System.tmp_dir!(), "rb_runner_cwd_#{System.unique_integer([:positive])}")
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

  defp run_to_completion(workflow, opts) do
    {:ok, run_id, pid} = WorkflowEngine.start_workflow(workflow, opts)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000
    {run_id, Workflows.get_run(run_id)}
  end

  defp adw_branches(repo) do
    {out, 0} = System.cmd("git", ["branch", "--list", "adw/*"], cd: repo)
    out
  end

  setup do
    original = Application.get_env(:repo_builder, :worktree)
    on_exit(fn -> Application.put_env(:repo_builder, :worktree, original) end)
    :ok
  end

  test "threads cwd + :worktree into the step session — the adw/<run_id> branch is provisioned in the target repo" do
    {base, repo} = git_repo()
    Application.put_env(:repo_builder, :worktree, scratch_base: Path.join(base, "scratch"))

    {:ok, wf} =
      WorkflowEngine.create_workflow_of_type("runner-cwd-#{uniq()}", "plan_build", "fake")

    {run_id, run} =
      run_to_completion(wf,
        cwd: repo,
        isolation_mode: :worktree,
        inputs: %{"input" => "do the thing"}
      )

    assert run.status in [:succeeded, :failed]
    # The session ran in the target repo: the reviewable branch survives cleanup.
    {branches, 0} = System.cmd("git", ["branch", "--list", "adw/#{run_id}"], cd: repo)
    assert branches =~ "adw/#{run_id}"

    # And the run records the worktree handoff (path + branch) for the UI.
    assert run.worktree_branch == "adw/#{run_id}"
    assert is_binary(run.worktree_path)
  end

  test "with no cwd the run is unchanged — no worktree branch is created in any repo" do
    {_base, repo} = git_repo()

    {:ok, wf} =
      WorkflowEngine.create_workflow_of_type("runner-nocwd-#{uniq()}", "plan_build", "fake")

    {_run_id, run} = run_to_completion(wf, inputs: %{"input" => "do the thing"})

    assert run.status in [:succeeded, :failed]
    assert run.worktree_branch == nil
    # The cwd-less run never touched the fixture repo.
    assert adw_branches(repo) == ""
  end

  defp uniq, do: System.unique_integer([:positive])
end
