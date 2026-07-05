defmodule RepoBuilder.Orchestrator.DriverTest do
  @moduledoc """
  Self-healing Phase 4: the autonomous drive loop. A real `Driver` + real `Queue` with an
  injected `starter` that simulates a turn (records a Progress entry, then dies so the Queue
  advances) — so the loop is fully deterministic and the test owns the clock via `Driver.tick/0`
  (`drive_interval_ms: :infinity`, `drive_on_boot: false`). `async: false`: shared sandbox so
  the Driver/Queue processes see the test's data, plus the singleton Driver/Breaker.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Budget
  alias RepoBuilder.Orchestrator.{Driver, Ledgers, Queue}
  alias RepoBuilder.Orchestrators

  setup do
    :ok = Driver.reset()
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

  # Start a real Queue for `orch_id` whose injected starter runs `turn_fn.(orch_id, prompt)`
  # (the simulated turn body) then returns a dead pid so the Queue's monitor advances it.
  defp queue_with(orch_id, turn_fn) do
    starter = fn oid, prompt ->
      _ = turn_fn.(oid, prompt)
      {:ok, spawn(fn -> :ok end), "orch-#{oid}-#{System.unique_integer([:positive])}"}
    end

    start_supervised!({Queue, orchestrator_id: orch_id, starter: starter}, id: {:queue, orch_id})
  end

  # Run one Driver tick, then flush the queue so the simulated turn's :DOWN is processed
  # (the queue returns to idle) before the next tick.
  defp tick(queue) do
    _ = Driver.tick()
    _ = :sys.get_state(queue)
    :ok
  end

  test "jump-starts an idle orchestrator with an active goal" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

    queue =
      queue_with(orch.id, fn oid, _p ->
        Ledgers.record_progress(oid, %{"made_progress" => true})
      end)

    assert Ledgers.latest_progress(orch.id) == nil
    tick(queue)
    # The drive turn ran: a progress entry now exists.
    assert Ledgers.latest_progress(orch.id) != nil
  end

  test "a progressing loop reaches :done and stops driving" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})
    counter = start_supervised!({Agent, fn -> 0 end}, id: :counter)

    turn_fn = fn oid, _p ->
      n = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
      Ledgers.record_progress(oid, %{"made_progress" => true})
      if n >= 2, do: Ledgers.mark_done(oid)
    end

    queue = queue_with(orch.id, turn_fn)

    tick(queue)
    tick(queue)
    tick(queue)

    # The goal completed; the loop stopped (no active ledger to drive).
    assert Ledgers.current(orch.id) == nil
  end

  test "no-progress turns trigger a replan turn then escalate" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})
    prompts = start_supervised!({Agent, fn -> [] end}, id: :prompts)

    turn_fn = fn oid, prompt ->
      Agent.update(prompts, &[prompt | &1])
      Ledgers.record_progress(oid, %{"made_progress" => false})
    end

    queue = queue_with(orch.id, turn_fn)

    handler = "esc-#{orch.id}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:repo_builder, :orchestrator, :escalated],
      fn _event, _measure, meta, _cfg -> send(test_pid, {:escalated, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    # tick 1,2 drive; the eval that BUMPS stall happens on the NEXT tick (acting on the prior
    # turn's entry). max_stall 2 ⇒ the 3rd drive turn is a REPLAN; escalate_after_stall 3 ⇒
    # the 4th tick escalates.
    tick(queue)
    tick(queue)
    tick(queue)

    assert [latest_prompt | _] = Agent.get(prompts, & &1)
    assert latest_prompt =~ "[REPLAN]"

    tick(queue)

    assert Ledgers.current(orch.id) == nil
    assert Orchestrators.holding_reason(elem(Orchestrators.fetch(orch.id), 1)) != nil
    assert_receive {:escalated, %{orchestrator_id: _}}, 1_000
  end

  test "transient (rate-limit) turns are ladder-neutral and never escalate" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})
    prompts = start_supervised!({Agent, fn -> [] end}, id: :prompts_transient)

    # Every turn dies on a transient provider condition (the auto-record backstop's
    # `:transient` entry). Mirrors the 2026-07-05 rate-limit incident.
    turn_fn = fn oid, prompt ->
      Agent.update(prompts, &[prompt | &1])

      Ledgers.record_progress(oid, %{
        "made_progress" => false,
        "on_track" => false,
        "transient" => true
      })
    end

    queue = queue_with(orch.id, turn_fn)

    # Four ticks — enough that non-transient no-progress turns would have escalated by now.
    tick(queue)
    tick(queue)
    tick(queue)
    tick(queue)

    ledger = Ledgers.current(orch.id)
    # The goal is NOT escalated: still active, stall budget untouched.
    assert ledger != nil
    assert ledger.status == :active
    assert ledger.stall_count == 0
    # The loop kept driving (no [REPLAN], no escalation) — normal drive prompts only.
    assert prompts_seen = Agent.get(prompts, & &1)
    refute Enum.any?(prompts_seen, &(&1 =~ "[REPLAN]"))
  end

  test "non-transient no-progress turns still escalate (regression guard)" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

    turn_fn = fn oid, _p ->
      Ledgers.record_progress(oid, %{"made_progress" => false, "transient" => false})
    end

    queue = queue_with(orch.id, turn_fn)

    tick(queue)
    tick(queue)
    tick(queue)
    tick(queue)

    # A genuine (non-transient) stall still climbs the ladder to escalation.
    assert Ledgers.current(orch.id) == nil
  end

  test "boot-resume drives an unfinished goal on Driver start" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

    queue =
      queue_with(orch.id, fn oid, _p ->
        Ledgers.record_progress(oid, %{"made_progress" => true})
      end)

    original = Application.get_env(:repo_builder, :orchestrator, [])
    Application.put_env(:repo_builder, :orchestrator, Keyword.put(original, :drive_on_boot, true))
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    boot_driver = start_supervised!({Driver, name: :boot_driver}, id: :boot_driver)
    # The boot continue runs before any message, so this is a barrier for the boot sweep.
    _ = :sys.get_state(boot_driver)
    _ = :sys.get_state(queue)

    assert Ledgers.latest_progress(orch.id) != nil
  end

  test "a tripped budget suppresses driving, then a release resumes it" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

    queue =
      queue_with(orch.id, fn oid, _p ->
        Ledgers.record_progress(oid, %{"made_progress" => true})
      end)

    Budget.Guard.engage_kill_switch()
    on_exit(fn -> Budget.Guard.release_all() end)

    tick(queue)
    assert Ledgers.latest_progress(orch.id) == nil

    Budget.Guard.release_all()
    tick(queue)
    assert Ledgers.latest_progress(orch.id) != nil
  end
end
