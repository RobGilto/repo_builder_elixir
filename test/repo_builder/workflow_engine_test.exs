defmodule RepoBuilder.WorkflowEngineTest do
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{WorkflowEngine, Workflows}

  @mock RepoBuilder.Harness.Mock

  defp uniq, do: System.unique_integer([:positive])

  # A harness whose session always fails (spawns `false` → non-clean exit → the
  # runtime synthesizes %Error{}).
  defp stub_failing_harness do
    register_harness("mock", @mock)
    stub(@mock, :command, fn _ -> {"false", [], [], %{harness: :mock}} end)
    stub(@mock, :normalize, fn _, _ -> :skip end)
  end

  defp run_to_completion(workflow, opts \\ []) do
    {:ok, run_id, pid} = WorkflowEngine.start_workflow(workflow, opts)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000
    Workflows.get_run(run_id)
  end

  test "the plan→build→review→fix ADW runs end-to-end to :succeeded with accumulated artifacts" do
    {:ok, wf} = WorkflowEngine.create_example_workflow("adw-ok-#{uniq()}", "fake")
    run = run_to_completion(wf, inputs: %{"input" => "ship it"})

    assert run.status == :succeeded
    # plan→build→review→:done (review succeeds), so fix is never run.
    assert Map.has_key?(run.artifacts, "plan")
    assert Map.has_key?(run.artifacts, "build")
    assert Map.has_key?(run.artifacts, "review")
    refute Map.has_key?(run.artifacts, "fix")
    # The run reached its terminal step before succeeding to :done.
    assert run.current_step == "review"
  end

  test "a failed step follows on_failure: :abort and ends the run as :failed" do
    stub_failing_harness()

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "adw-fail-#{uniq()}",
        steps: [
          %{
            "name" => "plan",
            "harness" => "mock",
            "on_success" => "done",
            "on_failure" => "abort"
          }
        ]
      })

    run = run_to_completion(wf)
    assert run.status == :failed
  end

  test "a failed step follows an on_failure BRANCH (review→fix) and can still succeed" do
    stub_failing_harness()

    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "adw-branch-#{uniq()}",
        steps: [
          %{
            "name" => "plan",
            "harness" => "fake",
            "on_success" => "review",
            "on_failure" => "abort"
          },
          %{
            "name" => "review",
            "harness" => "mock",
            "on_success" => "done",
            "on_failure" => "fix"
          },
          %{"name" => "fix", "harness" => "fake", "on_success" => "done", "on_failure" => "abort"}
        ]
      })

    run = run_to_completion(wf)

    assert run.status == :succeeded
    assert Map.has_key?(run.artifacts, "plan")
    assert Map.has_key?(run.artifacts, "fix")
    # review failed → produced no captured output.
    refute Map.has_key?(run.artifacts, "review")
  end

  test "a failing workflow is isolated from a second concurrent succeeding workflow" do
    stub_failing_harness()

    {:ok, failing} =
      Workflows.create_workflow(%{
        name: "adw-iso-fail-#{uniq()}",
        steps: [
          %{
            "name" => "plan",
            "harness" => "mock",
            "on_success" => "done",
            "on_failure" => "abort"
          }
        ]
      })

    {:ok, ok_wf} = WorkflowEngine.create_example_workflow("adw-iso-ok-#{uniq()}", "fake")

    {:ok, fail_id, fail_pid} = WorkflowEngine.start_workflow(failing)
    {:ok, ok_id, ok_pid} = WorkflowEngine.start_workflow(ok_wf, inputs: %{"input" => "go"})

    fail_ref = Process.monitor(fail_pid)
    ok_ref = Process.monitor(ok_pid)

    assert_receive {:DOWN, ^fail_ref, :process, _, :normal}, 8_000
    assert_receive {:DOWN, ^ok_ref, :process, _, :normal}, 8_000

    assert Workflows.get_run(fail_id).status == :failed
    assert Workflows.get_run(ok_id).status == :succeeded
  end
end
