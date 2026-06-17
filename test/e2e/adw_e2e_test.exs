defmodule RepoBuilder.E2E.AdwTest do
  @moduledoc """
  End-to-end tests for the ADW (AI Developer Workflow) system.

  These tests exercise the full tool-API layer (start_adw → check_adw polling) and
  the LiveView swimlane (ConsoleLive ADWS view) against real workflow runs on the Fake
  harness. They complement the unit/integration tests which stub or seed data:

  * `workflow_engine_test.exs` — runner integration (PID monitoring, Mox branching)
  * `adw_tools_test.exs`       — tool-layer unit tests (seeded data, type validation)
  * `test_adw_swimlane_test.exs` — LiveView swimlane with seeded + broadcast data

  What this file adds: polling `check_adw` until terminal for ALL three catalog types,
  the review→fix failure branch driven through the tool API, and a LiveView smoke test
  that starts a real run before mounting to confirm the lane seeds correctly on mount.

  `async: false` — live workflow runs use the session supervisor and shared sandbox.
  """
  use RepoBuilder.SessionCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint RepoBuilderWeb.Endpoint
  @mock RepoBuilder.Harness.Mock

  alias RepoBuilder.Orchestrator.Tools
  alias RepoBuilder.{Orchestrators, WorkflowEngine, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  defp new_orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "e2e-orch-#{uniq()}", harness: "fake"})
    orch
  end

  # Poll check_adw until terminal status or timeout; returns {:ok, summary} | {:timeout, summary}.
  defp await_terminal(orch_id, run_id, attempts \\ 120)

  defp await_terminal(orch_id, run_id, attempts) do
    case Tools.call("check_adw", orch_id, %{"run_id" => run_id}) do
      {:ok, %{"status" => s} = summary} when s in ["succeeded", "failed", "cancelled"] ->
        {:ok, summary}

      {:ok, _} when attempts > 0 ->
        Process.sleep(25)
        await_terminal(orch_id, run_id, attempts - 1)

      {:ok, summary} ->
        {:timeout, summary}

      err ->
        err
    end
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  # ---------------------------------------------------------------------------
  # 1. Full tool-API round-trips for all three catalog types
  # ---------------------------------------------------------------------------

  describe "plan_build workflow type (tool API)" do
    test "runs to succeeded with plan + build artifacts and 2/2 progress" do
      orch = new_orchestrator()

      assert {:ok, %{"run_id" => run_id, "workflow_type" => "plan_build"}} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "e2e test",
                 "harness" => "fake",
                 "workflow_type" => "plan_build"
               })

      assert {:ok, summary} = await_terminal(orch.id, run_id)
      assert summary["status"] == "succeeded"
      assert Map.has_key?(summary["artifacts"], "plan")
      assert Map.has_key?(summary["artifacts"], "build")
      refute Map.has_key?(summary["artifacts"], "review")

      steps = summary["steps"]
      assert length(steps) == 2
      assert Enum.all?(steps, &(&1["status"] == "succeeded"))
      assert summary["progress"] == %{"completed" => 2, "total" => 2}
    end
  end

  describe "plan_build_review workflow type (tool API)" do
    test "runs to succeeded with plan + build + review artifacts and 3/3 progress" do
      orch = new_orchestrator()

      assert {:ok, %{"run_id" => run_id, "workflow_type" => "plan_build_review"}} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "e2e test",
                 "harness" => "fake",
                 "workflow_type" => "plan_build_review"
               })

      assert {:ok, summary} = await_terminal(orch.id, run_id)
      assert summary["status"] == "succeeded"
      assert Map.has_key?(summary["artifacts"], "plan")
      assert Map.has_key?(summary["artifacts"], "build")
      assert Map.has_key?(summary["artifacts"], "review")
      refute Map.has_key?(summary["artifacts"], "fix")

      assert summary["progress"]["total"] == 3
      assert summary["progress"]["completed"] == 3
    end
  end

  describe "plan_build_review_fix workflow type (tool API)" do
    test "review passes — fix step not taken; 3/4 steps completed" do
      orch = new_orchestrator()

      assert {:ok, %{"run_id" => run_id}} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "e2e test",
                 "harness" => "fake",
                 "workflow_type" => "plan_build_review_fix"
               })

      assert {:ok, summary} = await_terminal(orch.id, run_id)
      assert summary["status"] == "succeeded"
      assert Map.has_key?(summary["artifacts"], "plan")
      assert Map.has_key?(summary["artifacts"], "build")
      assert Map.has_key?(summary["artifacts"], "review")
      refute Map.has_key?(summary["artifacts"], "fix")

      # 4 steps in catalog; fix never ran → still :pending → not counted as completed.
      assert summary["progress"]["total"] == 4
      assert summary["progress"]["completed"] == 3
    end
  end

  # ---------------------------------------------------------------------------
  # 2. plan_build_review_fix — review→fix failure branch (via tool API)
  # ---------------------------------------------------------------------------

  describe "plan_build_review_fix review→fix branch" do
    test "when review fails, fix step runs and the run succeeds" do
      # Wire a mock harness that always exits non-clean (like `false`), mirroring
      # the pattern in workflow_engine_test.exs.
      register_harness("mock", @mock)
      stub(@mock, :command, fn _ -> {"false", [], [], %{harness: :mock}} end)
      stub(@mock, :normalize, fn _, _ -> :skip end)

      orch = new_orchestrator()

      # Build the workflow manually: review on "mock" harness so it always fails,
      # triggering the on_failure → "fix" branch.
      {:ok, wf} =
        Workflows.create_workflow(%{
          name: "e2e-branch-#{uniq()}",
          type: "plan_build_review_fix",
          steps: [
            %{
              "name" => "plan",
              "harness" => "fake",
              "on_success" => "build",
              "on_failure" => "abort"
            },
            %{
              "name" => "build",
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
            %{
              "name" => "fix",
              "harness" => "fake",
              "on_success" => "done",
              "on_failure" => "abort"
            }
          ]
        })

      {:ok, run_id, pid} = WorkflowEngine.start_workflow(wf, inputs: %{"input" => "e2e branch"})

      # Monitor the runner so we know exactly when it exits.
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000

      assert {:ok, summary} = await_terminal(orch.id, run_id)
      assert summary["status"] == "succeeded"
      assert Map.has_key?(summary["artifacts"], "plan")
      assert Map.has_key?(summary["artifacts"], "build")
      assert Map.has_key?(summary["artifacts"], "fix")
      # review failed → produced no captured artifact.
      refute Map.has_key?(summary["artifacts"], "review")
    end
  end

  # ---------------------------------------------------------------------------
  # 3. LiveView: ConsoleLive ADWS swimlane reflects a completed run
  # ---------------------------------------------------------------------------

  describe "ConsoleLive ADWS swimlane" do
    test "a completed start_adw run appears in the ADWS lane with the correct step count" do
      orch = new_orchestrator()

      # Run the workflow to completion first so the run exists in DB when the
      # LiveView mounts (it seeds the most-recent runs on mount).
      assert {:ok, %{"run_id" => run_id}} =
               Tools.call("start_adw", orch.id, %{
                 "input" => "e2e liveview",
                 "harness" => "fake",
                 "workflow_type" => "plan_build"
               })

      assert {:ok, _summary} = await_terminal(orch.id, run_id)

      # Give PubSub a moment to flush before mounting so the lane's step states
      # reflect the final broadcast.
      Process.sleep(100)

      conn = build_conn()
      {:ok, view, _html} = live(conn, "/")

      # Switch to the ADWS view so workflow lanes render.
      view |> element("#view-toggle") |> render_click()

      html = render(view)
      # The completed run appears as a swimlane lane.
      assert html =~ "workflow-#{run_id}"
      # plan_build has 2 steps, both succeeded → 2/2.
      assert html =~ "2/2"
    end
  end
end
