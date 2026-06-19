defmodule RepoBuilder.WorkflowEngine.BudgetBlockTest do
  @moduledoc """
  The workflow runner consults the budget breaker before each step (issue-budget-guardrails).
  A tripped cap is isolated: the step follows its `on_failure` edge and the run ends
  cleanly (it never crashes the runner or another run), and the transition persists to
  `workflow_runs` (the source of truth, §7).

  `async: false` — drives the shared global `Budget.Guard` kill switch, released in
  `on_exit/1`.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Budget, WorkflowEngine, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  setup do
    on_exit(fn -> Budget.Guard.release_all() end)
    :ok
  end

  defp run_to_completion(workflow) do
    {:ok, run_id, pid} = WorkflowEngine.start_workflow(workflow, [])
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000
    Workflows.get_run(run_id)
  end

  test "a tripped budget makes the in-flight step follow on_failure (isolated, no crash)" do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "adw-budget-#{uniq()}",
        steps: [
          %{
            "name" => "plan",
            "harness" => "fake",
            "on_success" => "done",
            "on_failure" => "abort"
          }
        ]
      })

    Budget.Guard.engage_kill_switch()

    run = run_to_completion(wf)

    # The step was blocked, followed on_failure: :abort, and the run persisted as :failed
    # — no plan artifact was produced (the session never started).
    assert run.status == :failed
    refute Map.has_key?(run.artifacts, "plan")
  end
end
