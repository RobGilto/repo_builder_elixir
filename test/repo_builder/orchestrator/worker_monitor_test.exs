defmodule RepoBuilder.Orchestrator.WorkerMonitorTest do
  @moduledoc """
  Self-healing Phase 2 (push liveness): the per-orchestrator `Queue` `Process.monitor`s each
  dispatched worker pid, so a hard death that bypasses `terminate/2`
  (`Process.exit(pid, :kill)` / brutal shutdown — the gap the reaper documents at
  `server.ex:517-519`) is detected INSTANTLY: a `:DOWN` with no preceding worker-terminal and
  a row still optimistically `:running` synthesizes `worker_terminal{ok?: false}` and
  reconciles the worker to `:error` — milliseconds, not a ≤60 s reaper sweep.

  Real `Queue` GenServer + a real (Mock-harness) worker session kept alive by a long `sleep`
  child. `async: false`: shared sandbox + the live `SessionRegistry` + global Mox.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, Dashboard, Orchestrators}
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.Session.Supervisor

  @mock RepoBuilder.Harness.Mock

  setup do
    register_harness("mock", @mock)
    stub(@mock, :command, fn _opts -> {"/bin/sleep", ["120"], [], %{}} end)

    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    queue = start_supervised!({Queue, orchestrator_id: orch.id})
    :ok = Dashboard.subscribe_events()
    %{orch: orch, queue: queue}
  end

  # Create a worker row + a live (Mock sleep) session bound to it; monitor it on the Queue.
  defp dispatch_worker(orch, queue, status) do
    {:ok, worker} =
      Agents.create_worker(orch.id, %{
        "name" => "w-#{System.unique_integer([:positive])}",
        "harness" => "mock",
        "provider" => "anthropic"
      })

    {:ok, _} = Agents.set_status(worker.id, status)
    agent_id = "worker-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Supervisor.start_session(
        agent_id: agent_id,
        agent_db_id: worker.id,
        harness: "mock",
        prompt: "do work"
      )

    :ok = Queue.monitor_worker(orch.id, worker.id, pid)
    # Flush the monitor cast so the monitor is registered before we kill the pid.
    _ = :sys.get_state(queue)
    {worker, pid}
  end

  test "a hard-killed worker synthesizes a terminal and reconciles to :error", %{
    orch: orch,
    queue: queue
  } do
    {worker, pid} = dispatch_worker(orch, queue, :running)
    worker_id = worker.id

    Process.exit(pid, :kill)

    assert_receive {:agent_updated, %Agent{id: ^worker_id, status: :error}}, 2_000
    assert Agents.get_agent(worker_id).status == :error
  end

  test "a clean terminal does NOT double-fire on the trailing DOWN", %{orch: orch, queue: queue} do
    {worker, pid} = dispatch_worker(orch, queue, :idle)
    worker_id = worker.id

    # A real clean terminal landed: the row moved to :idle and the Queue saw the
    # worker-terminal (marks saw_terminal? so the trailing DOWN is a no-op).
    Dashboard.broadcast_worker_terminal(orch.id, %{
      worker_id: worker_id,
      name: worker.name,
      ok?: true
    })

    _ = :sys.get_state(queue)

    Process.exit(pid, :kill)

    refute_receive {:agent_updated, %Agent{id: ^worker_id, status: :error}}, 300
    assert Agents.get_agent(worker_id).status == :idle
  end

  test "a DOWN for a row already off :running does not synthesize (Case-B race guard)", %{
    orch: orch,
    queue: queue
  } do
    # saw_terminal? is false (no worker-terminal seen), but the row already moved off
    # :running — a terminal must have landed before the monitor registered, so no synth.
    {worker, pid} = dispatch_worker(orch, queue, :idle)
    worker_id = worker.id

    Process.exit(pid, :kill)

    refute_receive {:agent_updated, %Agent{id: ^worker_id, status: :error}}, 300
    assert Agents.get_agent(worker_id).status == :idle
  end
end
