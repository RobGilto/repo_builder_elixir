defmodule RepoBuilder.Orchestrator.AdwToolsTest do
  @moduledoc """
  Unit tests for the ADW-catalog additions to the orchestrator tools: `start_adw`'s
  catalog-validated `workflow_type` (default + unknown-type error) and the enriched
  `check_adw` (progress + per-step status list + activity tail). Workers run on the
  keyless Fake harness; the Repo is the test sandbox.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.{Orchestrators, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  defp orchestrator(harness \\ "fake") do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: harness})
    orch
  end

  defp assert_run_terminal(run_id, attempts \\ 80) do
    case Workflows.get_run(run_id) do
      %{status: status} when status in [:succeeded, :failed, :cancelled] ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(25)
        assert_run_terminal(run_id, attempts - 1)

      _ ->
        flunk("workflow #{run_id} did not reach a terminal state")
    end
  end

  describe "start_adw workflow_type" do
    test "defaults to the catalog default when omitted (back-compat)" do
      orch = orchestrator()

      assert {:ok, %{"run_id" => run_id, "workflow_type" => "plan_build_review_fix"}} =
               Tools.call("start_adw", orch.id, %{"input" => "ship it", "harness" => "fake"})

      run = Workflows.get_run(run_id)
      workflow = Workflows.get_workflow(run.workflow_id)
      assert workflow.type == "plan_build_review_fix"
      assert_run_terminal(run_id)
    end

    test "builds the catalog shape for an explicit type" do
      orch = orchestrator()

      assert {:ok, %{"run_id" => run_id, "workflow_type" => "plan_build"}} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "ship it",
                 "harness" => "fake",
                 "workflow_type" => "plan_build"
               })

      run = Workflows.get_run(run_id)
      workflow = Workflows.get_workflow(run.workflow_id)
      assert workflow.type == "plan_build"
      assert Enum.map(workflow.steps, & &1["name"]) == ["plan", "build"]
      assert_run_terminal(run_id)
    end

    test "an unknown type is a helpful error listing the available slugs (no crash)" do
      orch = orchestrator()

      assert {:error, reason} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "x",
                 "harness" => "fake",
                 "workflow_type" => "bogus"
               })

      assert reason =~ "unknown workflow_type bogus"
      assert reason =~ "plan_build_review_fix"
    end
  end

  describe "check_adw enrichment" do
    test "returns progress, per-step statuses, an activity tail, and keeps legacy keys" do
      orch = orchestrator()

      # Seed a run with per-step state so the assertions don't race the live runner.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "wf-#{uniq()}",
          type: "plan_build",
          steps: [
            %{"name" => "plan", "harness" => "fake", "on_success" => "build"},
            %{"name" => "build", "harness" => "fake", "on_success" => "done"}
          ]
        })

      {:ok, run} =
        Workflows.create_run(%{workflow_id: wf.id, status: :running, current_step: "build"})

      {:ok, run} = Workflows.put_step_state(run, "plan", %{status: "succeeded", cost_usd: "0.01"})
      {:ok, _run} = Workflows.put_step_state(run, "build", %{status: "running"})

      assert {:ok, summary} = Tools.call("check_adw", orch.id, %{"run_id" => run.id})

      # Legacy keys preserved (no regression).
      assert summary["run_id"] == run.id
      assert summary["status"] == "running"
      assert summary["current_step"] == "build"
      assert Map.has_key?(summary, "artifacts")

      # New per-step observability.
      assert summary["progress"] == %{"completed" => 1, "total" => 2}

      [plan, build] = summary["steps"]
      assert plan["name"] == "plan"
      assert plan["status"] == "succeeded"
      assert plan["cost_usd"] == "0.01"
      assert build["status"] == "running"

      assert is_list(summary["tail"])
    end

    test "an unknown run is still {:error, :not_found}" do
      orch = orchestrator()

      assert {:error, :not_found} =
               Tools.call("check_adw", orch.id, %{"run_id" => Ecto.UUID.generate()})
    end
  end
end
