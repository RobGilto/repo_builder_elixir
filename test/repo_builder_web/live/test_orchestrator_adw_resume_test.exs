defmodule RepoBuilderWeb.TestOrchestratorAdwResumeTest do
  @moduledoc """
  LiveView re-engagement proof for the WorkflowEngine-path ADW gap (issue-fallback):
  when an orchestrator-launched engine ADW finishes, the console must re-engage with one
  auto-resume turn rather than staying idle (the engine-path twin of the log-2618 hang).

  A controllable `Queue` (pluggable `:starter`) is pre-started for the default
  orchestrator BEFORE mount so the busy transition is deterministic. The terminal wakeup
  is delivered through the REAL `Runner.finalize/1` → `emit_orchestrator_resume/2` seam by
  running an actual Fake-harness engine workflow tied to the orchestrator.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.{Orchestrators, WorkflowEngine, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  defp controllable_starter(test_pid) do
    fn _orchestrator_id, prompt ->
      turn = spawn(fn -> receive(do: (:stop -> :ok)) end)
      send(test_pid, {:turn_started, prompt, turn})
      {:ok, turn, "agent-#{uniq()}"}
    end
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  defp engine_workflow do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "adw-engine-#{uniq()}",
        type: "plan_build",
        steps: [
          %{
            "name" => "plan",
            "harness" => "fake",
            "on_success" => "done",
            "on_failure" => "abort"
          }
        ]
      })

    wf
  end

  setup do
    original = Application.get_env(:repo_builder, :orchestrator)
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(original, :auto_resume_on_worker_return, true)
    )

    {:ok, orch} = Orchestrators.get_or_create_default()
    start_supervised!({Queue, orchestrator_id: orch.id, starter: controllable_starter(self())})
    %{orch: orch}
  end

  test "an orchestrator-launched engine ADW re-engages the console on terminal", %{
    conn: conn,
    orch: orch
  } do
    {:ok, view, _html} = live(conn, ~p"/")

    # Start a real Fake-harness engine workflow tied to the orchestrator and let it run to
    # terminal so the live seam broadcasts {:worker_terminal, …}.
    {:ok, _run_id, _pid} =
      WorkflowEngine.start_workflow(engine_workflow(),
        orchestrator_id: orch.id,
        inputs: %{"input" => "x"}
      )

    # The owed resume fires exactly once with an :auto_resume "Review" prompt, and the
    # console renders the orchestrator busy again (re-engaged) rather than idle.
    assert_receive {:turn_started, prompt, _resume_turn}, 8_000
    assert prompt =~ "Review"

    assert wait_until(fn -> has_element?(view, "#orchestrator-queue", "Busy") end)
  end
end
