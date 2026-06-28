defmodule RepoBuilder.Session.QuiescentWorkerReengageTest do
  @moduledoc """
  Regression for issue quiescent-worker-reengages-orchestrator: when the soft quiescence
  watchdog demotes a dispatched, orchestrator-OWNED worker `:running → :idle`, it must ALSO
  emit ONE idle-flavored worker-terminal signal on `orchestrator:<id>:workers` so the owning
  orchestrator's Queue re-engages and reviews the stranded output. Pre-fix the demotion was
  a SILENT status change (only `agent_updated`) and the orchestrator sat idle indefinitely.

  Drives the quiescence timer DETERMINISTICALLY by sending `:quiescence` to the live
  `Session.Server` (no 90 s wait). `async: false`: shared sandbox + live `SessionRegistry`
  + global Mox.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.{Agents, Dashboard}
  alias RepoBuilder.Session.Supervisor

  @mock RepoBuilder.Harness.Mock

  setup do
    register_harness("mock", @mock)
    # A long-lived child so the session stays alive while we drive the timer by hand.
    stub(@mock, :command, fn _opts -> {"/bin/sleep", ["120"], [], %{}} end)
    :ok
  end

  # Start a live worker session, optionally bound to an orchestrator. Returns {agent, pid}.
  defp start_worker(opts \\ []) do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "w-#{System.unique_integer([:positive])}",
        harness: "mock",
        provider: "anthropic"
      })

    agent_id = "worker-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Supervisor.start_session(
        [agent_id: agent_id, agent_db_id: agent.id, harness: "mock", prompt: "do work"] ++ opts
      )

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          _kind, _reason -> :ok
        end
      end
    end)

    {agent, pid}
  end

  test "a quiescent orchestrator-owned worker emits exactly one idle worker-terminal" do
    orch_id = Ecto.UUID.generate()
    :ok = Dashboard.subscribe_orchestrator_workers(orch_id)

    {agent, pid} = start_worker(orchestrator_id: orch_id, agent_name: "mech-facing-builder")
    db_id = agent.id
    {:ok, _} = Agents.set_status(db_id, :running)

    send(pid, :quiescence)

    assert_receive {:worker_terminal,
                    %{worker_id: ^db_id, name: "mech-facing-builder", idle?: true} = info},
                   2_000

    # The idle flavor, NOT the holding flavor and NOT a failure.
    assert info.ok? == true
    assert info.holding? == false

    # Exactly one — the `:quiescence` timer fires once per quiet window.
    refute_receive {:worker_terminal, _info}, 300

    # Still ALIVE + demoted to :idle (resumable in place).
    assert Process.alive?(pid)
    assert Agents.get_agent(db_id).status == :idle
  end

  test "a worker with no owning orchestrator emits NO idle signal" do
    # Subscribe to an unrelated orchestrator topic; the unscoped worker resolves no owner.
    other_orch = Ecto.UUID.generate()
    :ok = Dashboard.subscribe_orchestrator_workers(other_orch)

    {agent, pid} = start_worker()
    {:ok, _} = Agents.set_status(agent.id, :running)

    send(pid, :quiescence)

    refute_receive {:worker_terminal, _info}, 300
    # Still demoted (the silent-demotion behavior is unchanged for unscoped workers).
    assert Agents.get_agent(agent.id).status == :idle
  end
end
