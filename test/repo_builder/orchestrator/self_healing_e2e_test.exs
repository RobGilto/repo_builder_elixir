defmodule RepoBuilder.Orchestrator.SelfHealingE2ETest do
  @moduledoc """
  Self-healing Phase 6: the end-to-end acceptance gate. Exercises the whole stack with no
  operator input:

    * fire-and-walk-away — the Driver drives a goal to `:done` and stops, recording a reflection;
    * stall → replan → escalate — no-progress turns raise the away-human escalation (ledger
      `:escalated` + holding-reason banner state + a notification telemetry event);
    * the honest-state substrate — a live worker softens to `:idle` (alive, Phase 1) and a
      hard-killed running worker is reconciled to `:error` via the Queue's instant synthetic
      terminal (Phase 2), re-engaging the leader.

  `async: false`: real sessions + the live registries + the singleton Driver/Breaker + global Mox.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.Agents
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Dashboard
  alias RepoBuilder.Orchestrator.{Driver, Ledgers, Queue, Reflections, Tools}
  alias RepoBuilder.Orchestrators
  alias RepoBuilder.Session.Supervisor

  @mock RepoBuilder.Harness.Mock

  setup do
    :ok = Driver.reset()
    register_harness("mock", @mock)
    stub(@mock, :command, fn _opts -> {"/bin/sleep", ["120"], [], %{}} end)
    stub(@mock, :normalize, fn _raw, _ctx -> :skip end)
    :ok
  end

  defp create_orch do
    {:ok, orch} =
      Orchestrators.create(%{
        name: "orch-#{System.unique_integer([:positive])}",
        harness: "fake",
        model: "fake-model"
      })

    orch
  end

  # A real Queue whose injected starter runs the simulated turn body then dies (advances).
  defp queue_with(orch_id, turn_fn) do
    starter = fn oid, prompt ->
      _ = turn_fn.(oid, prompt)
      {:ok, spawn(fn -> :ok end), "orch-#{oid}-#{System.unique_integer([:positive])}"}
    end

    start_supervised!({Queue, orchestrator_id: orch_id, starter: starter}, id: {:queue, orch_id})
  end

  defp tick(queue) do
    _ = Driver.tick()
    _ = :sys.get_state(queue)
    :ok
  end

  test "fire-and-walk-away: the Driver drives a goal to :done with no operator input" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "ship it", definition_of_done: "verified"})
    counter = start_supervised!({Elixir.Agent, fn -> 0 end}, id: :counter)

    turn_fn = fn oid, _prompt ->
      n = Elixir.Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      Ledgers.record_progress(oid, %{"made_progress" => true, "summary" => "step #{n}"})
      # The leader reports completion via the real tool (which marks the goal done AND records a
      # Reflexion lesson) once the work is verified — exactly the brain's report_complete path.
      if n >= 2, do: Tools.call("report_complete", oid, %{"summary" => "shipped it"})
    end

    queue = queue_with(orch.id, turn_fn)

    Enum.each(1..3, fn _ -> tick(queue) end)

    # The goal completed autonomously; the loop stopped, and a reflection was captured.
    assert Ledgers.current(orch.id) == nil
    assert [%{} | _] = Reflections.list_recent(nil, 5)
  end

  test "stall → replan → escalate raises the away-human escalation" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "stuck goal", definition_of_done: "d"})

    queue =
      queue_with(orch.id, fn oid, _p ->
        Ledgers.record_progress(oid, %{"made_progress" => false})
      end)

    handler = "e2e-esc-#{orch.id}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:repo_builder, :orchestrator, :escalated],
      fn _e, _m, meta, _c -> send(test_pid, {:escalated, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    Enum.each(1..4, fn _ -> tick(queue) end)

    assert Ledgers.current(orch.id) == nil
    assert Orchestrators.holding_reason(elem(Orchestrators.fetch(orch.id), 1)) != nil
    assert_receive {:escalated, %{orchestrator_id: _}}, 1_000
  end

  test "honest-state substrate: a worker softens to :idle and a hard-kill reconciles to :error" do
    orch = create_orch()
    queue = start_supervised!({Queue, orchestrator_id: orch.id}, id: {:queue, orch.id})
    :ok = Dashboard.subscribe_events()

    # Phase 1 — a live worker goes quiet and is demoted to :idle while staying alive.
    {:ok, quiet} =
      Agents.create_worker(orch.id, %{
        "name" => "quiet-#{System.unique_integer([:positive])}",
        "harness" => "mock",
        "provider" => "anthropic"
      })

    quiet_id = quiet.id
    {:ok, _} = Agents.set_status(quiet_id, :running)

    {:ok, quiet_pid} =
      Supervisor.start_session(
        agent_id: "w-#{System.unique_integer([:positive])}",
        agent_db_id: quiet_id,
        harness: "mock",
        prompt: "x"
      )

    send(quiet_pid, :quiescence)
    assert_receive {:agent_updated, %Agent{id: ^quiet_id, status: :idle}}, 2_000
    assert Process.alive?(quiet_pid)

    # Phase 2 — a running monitored worker is hard-killed; the Queue synthesizes a terminal and
    # reconciles it to :error instantly (no reaper wait).
    {:ok, doomed} =
      Agents.create_worker(orch.id, %{
        "name" => "doomed-#{System.unique_integer([:positive])}",
        "harness" => "mock",
        "provider" => "anthropic"
      })

    doomed_id = doomed.id
    {:ok, _} = Agents.set_status(doomed_id, :running)

    {:ok, doomed_pid} =
      Supervisor.start_session(
        agent_id: "w-#{System.unique_integer([:positive])}",
        agent_db_id: doomed_id,
        harness: "mock",
        prompt: "x"
      )

    :ok = Queue.monitor_worker(orch.id, doomed_id, doomed_pid)
    _ = :sys.get_state(queue)
    Process.exit(doomed_pid, :kill)

    assert_receive {:agent_updated, %Agent{id: ^doomed_id, status: :error}}, 2_000
    assert Agents.get_agent(doomed_id).status == :error
  end
end
