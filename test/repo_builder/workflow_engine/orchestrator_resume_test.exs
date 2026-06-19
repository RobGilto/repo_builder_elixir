defmodule RepoBuilder.WorkflowEngine.OrchestratorResumeTest do
  @moduledoc """
  Proves a WorkflowEngine ADW run re-engages its launching orchestrator's holding
  pattern on terminal (issue-fallback). When `start_workflow/2` is given an
  `orchestrator_id`, the live `Runner.finalize/1` broadcasts `{:worker_terminal,
  %{worker_id, name, ok?}}` on `orchestrator:<id>:workers` — the exact shape the
  `Queue` consumes. A run with no `orchestrator_id` broadcasts nothing.

  `async: false` — the Runner starts a Fake session.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Dashboard, Orchestrators, WorkflowEngine, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator_id do
    {:ok, orch} = Orchestrators.get_or_create_default()
    orch.id
  end

  defp fake_workflow(success?) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "adw-resume-#{uniq()}",
        type: "plan_build",
        steps: [
          %{
            "name" => "plan",
            "harness" => "fake",
            "on_success" => if(success?, do: "done", else: "abort"),
            "on_failure" => "abort"
          }
        ]
      })

    wf
  end

  test "an orchestrator-launched run broadcasts a worker-terminal wakeup on success" do
    orchestrator_id = orchestrator_id()
    :ok = Dashboard.subscribe_orchestrator_workers(orchestrator_id)

    {:ok, run_id, _pid} =
      WorkflowEngine.start_workflow(fake_workflow(true),
        orchestrator_id: orchestrator_id,
        inputs: %{"input" => "x"}
      )

    assert_receive {:worker_terminal, %{worker_id: ^run_id, ok?: true, name: name}}, 8_000
    assert is_binary(name)
  end

  test "a run with no orchestrator_id broadcasts nothing" do
    orchestrator_id = orchestrator_id()
    :ok = Dashboard.subscribe_orchestrator_workers(orchestrator_id)

    {:ok, _run_id, pid} =
      WorkflowEngine.start_workflow(fake_workflow(true), inputs: %{"input" => "x"})

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000
    refute_receive {:worker_terminal, _}, 200
  end
end
