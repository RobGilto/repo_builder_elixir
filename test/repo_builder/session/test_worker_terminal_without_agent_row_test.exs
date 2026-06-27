defmodule RepoBuilder.Session.WorkerTerminalWithoutAgentRowTest do
  @moduledoc """
  Regression for the dropped worker-terminal re-engage signal (issue worker-terminal:
  "workers finish but the orchestrator does not pick up that the agents finished").

  The worker→orchestrator re-engage broadcast (`orchestrator:<id>:workers`) must fire
  from the owning `orchestrator_id` CAPTURED AT SPAWN, NOT from a terminal-time
  `Agents.get_agent/1` read. So even when the worker's `agents` row is gone by the time
  it reaches its terminal event — the wind-down / handover / force-retire reaps, an
  operator deletion, or a double-terminal race — the `Queue` is still notified and the
  orchestrator can auto-resume.

  Before the fix the broadcast was gated on a live DB read and was silently dropped when
  the row was missing. Drives the Mock adapter to emit one terminal Done, mirroring §6
  and `HoldingClassificationTest`. `async: false` (shared sandbox + global Mox).
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, Dashboard, Orchestrators, Repo}
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Session.Supervisor

  @mock RepoBuilder.Harness.Mock

  # Emit exactly one ordinary successful terminal Done frame.
  defp stub_done do
    stub(@mock, :command, fn _ ->
      {"printf", ["%s\n", ~s({"k":"done"})], [], %{harness: :mock}}
    end)

    stub(@mock, :normalize, fn
      %{"k" => "done"}, _ ->
        {:ok, [%Event.Done{harness: :mock, ok: true, reason: :success, final_text: "done"}]}

      _, _ ->
        :skip
    end)
  end

  defp create_worker(orchestrator_id) do
    {:ok, worker} =
      Agents.create_worker(orchestrator_id, %{
        "name" => "w-#{System.unique_integer([:positive])}",
        "harness" => "mock",
        "provider" => "anthropic",
        "model" => "mock-model",
        "session_id" => "sess-#{System.unique_integer([:positive])}"
      })

    worker
  end

  setup do
    register_harness("mock", @mock)
    {:ok, orch} = Orchestrators.get_or_create_default()
    :ok = Dashboard.subscribe_orchestrator_workers(orch.id)
    %{orch: orch}
  end

  test "worker-terminal still broadcasts when the agent row can't supply orchestrator_id", %{
    orch: orch
  } do
    worker = create_worker(orch.id)
    worker_id = worker.id
    subscribe(worker.id)
    stub_done()

    # Simulate the real-world drop condition deterministically: by terminal time the agent
    # row no longer yields the owning orchestrator (the wind-down/handover/force-retire reaps
    # nilify it, an operator deletion removes it, a double-terminal races the reap). The row
    # is kept (so the os_pid ledger FK is satisfied and the session actually spawns), but its
    # `orchestrator_id` is gone — pre-fix this made `maybe_emit_worker_terminal/2` silently
    # drop the broadcast. The spawn opts still carry the owning orchestrator + name, which is
    # the authoritative source the broadcast must now key off.
    worker
    |> Ecto.Changeset.change(orchestrator_id: nil)
    |> Repo.update!()

    assert %Agent{orchestrator_id: nil} = Agents.get_agent(worker_id)

    {:ok, pid} =
      Supervisor.start_session(
        agent_id: worker.id,
        agent_db_id: worker.id,
        agent_name: worker.name,
        orchestrator_id: orch.id,
        harness: "mock",
        prompt: "x"
      )

    ref = Process.monitor(pid)

    # The re-engage signal fires from the spawn-captured orchestrator_id — pre-fix this was
    # dropped because the DB read returned nil.
    assert_receive {:worker_terminal, %{worker_id: ^worker_id, ok?: true, name: name}}, 2_000
    assert name == worker.name

    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end

  test "happy path unchanged: a live worker row still broadcasts worker-terminal", %{orch: orch} do
    worker = create_worker(orch.id)
    worker_id = worker.id
    subscribe(worker.id)
    stub_done()

    {:ok, pid} =
      Supervisor.start_session(
        agent_id: worker.id,
        agent_db_id: worker.id,
        agent_name: worker.name,
        orchestrator_id: orch.id,
        harness: "mock",
        prompt: "x"
      )

    ref = Process.monitor(pid)

    assert_receive {:worker_terminal, %{worker_id: ^worker_id, ok?: true, holding?: false}}, 2_000
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000
  end
end
