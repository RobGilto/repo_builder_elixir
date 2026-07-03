defmodule RepoBuilder.WorkflowEngine.RunnerMergeTest do
  @moduledoc """
  The deterministic terminal `merge` step (issue-adw-non-iso-merge): a
  `isolation_mode: :worktree` run gains a launch-time `merge` step that lands the
  `adw/<run_id>` branch on the detected trunk and persists
  `merge_status`/`merged_sha` on `workflow_runs`; a direct-mode run is untouched
  (no merge step injected, `merge_status` stays NULL).

  `async: false` (shared sandbox reaches the spawned Runner + session), mirroring
  `RunnerCwdTest`.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{WorkflowEngine, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  defp git_repo(trunk) do
    base = Path.join(System.tmp_dir!(), "rb_runner_merge_#{System.unique_integer([:positive])}")
    repo = Path.join(base, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("git", ["init", "-q", "-b", trunk], cd: repo)
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

  setup do
    original = Application.get_env(:repo_builder, :worktree)
    on_exit(fn -> Application.put_env(:repo_builder, :worktree, original) end)
    :ok
  end

  test "a :worktree run on a dev-trunk repo ends merged with a recorded sha" do
    {base, repo} = git_repo("dev")
    Application.put_env(:repo_builder, :worktree, scratch_base: Path.join(base, "scratch"))

    {:ok, wf} =
      WorkflowEngine.create_workflow_of_type("runner-merge-#{uniq()}", "plan_build", "fake")

    {_run_id, run} = run_to_completion(wf, cwd: repo, isolation_mode: :worktree)

    assert run.status == :succeeded
    assert run.merge_status == :merged
    assert run.merged_sha =~ ~r/^[0-9a-f]{40}$/
    # The merge step is visible in the per-step observability map.
    assert %{"status" => "succeeded"} = run.step_states["merge"]
    # The trunk HEAD is the recorded sha (the adw branch landed on dev).
    {out, 0} = System.cmd("git", ["rev-parse", "dev"], cd: repo)
    assert String.trim(out) == run.merged_sha
  end

  test "a direct-mode run gets no merge step and merge_status stays NULL" do
    {:ok, wf} =
      WorkflowEngine.create_workflow_of_type("runner-direct-#{uniq()}", "plan_build", "fake")

    {_run_id, run} = run_to_completion(wf, [])

    assert run.status == :succeeded
    assert is_nil(run.merge_status)
    refute Map.has_key?(run.step_states, "merge")
  end
end
