defmodule RepoBuilder.WorkflowsTest do
  @moduledoc """
  Unit tests for the per-step observability substrate on the `Workflows` context:
  `put_step_state/3` merge semantics and `run_progress/1` derivation (total/completed/
  current/per-step status), including the branching `review → fix` case and a fresh
  (empty `step_states`) run.
  """
  use RepoBuilder.DataCase, async: true

  alias RepoBuilder.Workflows

  defp uniq, do: System.unique_integer([:positive])

  defp workflow(steps) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "wf-#{uniq()}",
        type: "plan_build_review_fix",
        steps: steps
      })

    wf
  end

  defp run_for(steps) do
    wf = workflow(steps)

    {:ok, run} =
      Workflows.create_run(%{workflow_id: wf.id, status: :running, current_step: "plan"})

    run
  end

  @three_steps [
    %{"name" => "plan", "harness" => "fake", "on_success" => "build"},
    %{"name" => "build", "harness" => "fake", "on_success" => "review"},
    %{"name" => "review", "harness" => "fake", "on_success" => "done"}
  ]

  describe "put_step_state/3" do
    test "merges one step without clobbering siblings" do
      run = run_for(@three_steps)

      {:ok, run} = Workflows.put_step_state(run, "plan", %{status: "succeeded", cost_usd: "0.01"})
      {:ok, run} = Workflows.put_step_state(run, "build", %{status: "running"})

      assert run.step_states["plan"]["status"] == "succeeded"
      assert run.step_states["plan"]["cost_usd"] == "0.01"
      assert run.step_states["build"]["status"] == "running"
    end

    test "a second write to the same step merges (does not replace) its attrs" do
      run = run_for(@three_steps)

      {:ok, run} = Workflows.put_step_state(run, "plan", %{status: "running", started_at: "t0"})

      {:ok, run} =
        Workflows.put_step_state(run, "plan", %{status: "succeeded", finished_at: "t1"})

      assert run.step_states["plan"]["status"] == "succeeded"
      # started_at from the first write survives the second.
      assert run.step_states["plan"]["started_at"] == "t0"
      assert run.step_states["plan"]["finished_at"] == "t1"
    end

    test "stringifies atom keys" do
      run = run_for(@three_steps)
      {:ok, run} = Workflows.put_step_state(run, "plan", %{status: "succeeded"})
      assert run.step_states["plan"]["status"] == "succeeded"
    end
  end

  describe "run_progress/1" do
    test "a fresh run with no step_states is all :pending, completed 0" do
      run = run_for(@three_steps)
      progress = Workflows.run_progress(run)

      assert progress.total == 3
      assert progress.completed == 0
      assert progress.current == "plan"
      assert Enum.map(progress.steps, & &1.name) == ["plan", "build", "review"]
      assert Enum.all?(progress.steps, &(&1.status == :pending))
    end

    test "orders steps by the workflow and counts completed succeeded steps" do
      run = run_for(@three_steps)
      {:ok, run} = Workflows.put_step_state(run, "plan", %{status: "succeeded", cost_usd: "0.02"})
      {:ok, run} = Workflows.put_step_state(run, "build", %{status: "running"})
      {:ok, run} = Workflows.update_run(run, %{current_step: "build"})

      progress = Workflows.run_progress(run)

      assert progress.completed == 1
      assert progress.current == "build"
      [plan, build, review] = progress.steps
      assert plan.status == :succeeded
      assert plan.cost_usd == "0.02"
      assert build.status == :running
      assert review.status == :pending
    end

    test "the branching review → fix case is represented coherently" do
      steps = [
        %{"name" => "plan", "harness" => "fake", "on_success" => "build"},
        %{"name" => "build", "harness" => "fake", "on_success" => "review"},
        %{
          "name" => "review",
          "harness" => "fake",
          "on_success" => "done",
          "on_failure" => "fix"
        },
        %{"name" => "fix", "harness" => "fake", "on_success" => "done"}
      ]

      run = run_for(steps)
      {:ok, run} = Workflows.put_step_state(run, "plan", %{status: "succeeded"})
      {:ok, run} = Workflows.put_step_state(run, "build", %{status: "succeeded"})
      {:ok, run} = Workflows.put_step_state(run, "review", %{status: "failed"})
      {:ok, run} = Workflows.put_step_state(run, "fix", %{status: "succeeded"})
      {:ok, run} = Workflows.update_run(run, %{current_step: "fix", status: :succeeded})

      progress = Workflows.run_progress(run)

      assert progress.total == 4
      # plan + build + fix succeeded; the failed review is NOT double-counted.
      assert progress.completed == 3
      review = Enum.find(progress.steps, &(&1.name == "review"))
      assert review.status == :failed
    end
  end
end
