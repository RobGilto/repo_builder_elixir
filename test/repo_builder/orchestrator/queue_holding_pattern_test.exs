defmodule RepoBuilder.Orchestrator.QueueHoldingPatternTest do
  @moduledoc """
  Focused unit tests for the queue's holding pattern (issue holding-pattern-followup):
  the anti-amnesia `pending_resume?` memory that guarantees a worker which returns
  mid-turn is reviewed exactly once after the turn drains — event-driven, coalesced,
  no polling.

  Drives the `Queue` with a controllable `:starter` (no real harness) so every busy/idle
  transition is deterministic, and forces `auto_resume_on_worker_return: true` per scope
  (config/test.exs ships it `false`).
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Orchestrator.Queue

  # Spawns a controllable "turn" process, notifies the test of the started prompt + pid,
  # and returns the {pid, agent_id} the queue monitors. Send the pid `:stop` (via
  # finish_turn/1) to simulate the turn finishing — its :DOWN advances/drains the queue.
  defp controllable_starter(test_pid) do
    fn _orchestrator_id, prompt ->
      turn = spawn(fn -> receive(do: (:stop -> :ok)) end)
      send(test_pid, {:turn_started, prompt, turn})
      {:ok, turn, "agent-#{prompt}"}
    end
  end

  defp start_queue(starter) do
    id = Ecto.UUID.generate()
    pid = start_supervised!({Queue, orchestrator_id: id, starter: starter})
    {id, pid}
  end

  defp finish_turn(turn_pid) do
    ref = Process.monitor(turn_pid)
    send(turn_pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^turn_pid, _}, 1_000
  end

  defp enable_auto_resume do
    original = Application.get_env(:repo_builder, :orchestrator)
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(original, :auto_resume_on_worker_return, true)
    )
  end

  test "a worker that returns mid-turn schedules exactly one resume after the turn drains" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    # An operator turn is in flight...
    assert {:ok, :started, _} = Queue.enqueue(id, "operator")
    assert_receive {:turn_started, "operator", turn}, 1_000

    # ...the worker returns WHILE the turn is still running. Pre-fix this is dropped.
    send(pid, {:worker_terminal, %{name: "w1", ok?: true}})
    refute_receive {:turn_started, _prompt, _}, 200

    # When the turn drains, the owed resume fires exactly once, naming the worker.
    finish_turn(turn)
    assert_receive {:turn_started, prompt, _resume_turn}, 1_000
    assert prompt =~ "w1"
    assert prompt =~ "Review"

    assert %{busy?: true, depth: 0} = Queue.snapshot(id)
  end

  test "a burst of mid-turn returns coalesces to a single resume turn" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, _} = Queue.enqueue(id, "operator")
    assert_receive {:turn_started, "operator", turn}, 1_000

    send(pid, {:worker_terminal, %{name: "w1", ok?: true}})
    send(pid, {:worker_terminal, %{name: "w2", ok?: false}})
    refute_receive {:turn_started, _prompt, _}, 200

    finish_turn(turn)

    # Exactly one auto-resume turn — the burst coalesced to a single owed resume.
    assert_receive {:turn_started, _prompt, _resume_turn}, 1_000
    refute_receive {:turn_started, _prompt2, _}, 200
  end

  test "an operator message front-runs and clears a pending resume" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, _} = Queue.enqueue(id, "operator-1")
    assert_receive {:turn_started, "operator-1", turn1}, 1_000

    # A worker returns mid-turn (owes a resume)...
    send(pid, {:worker_terminal, %{name: "w1", ok?: true}})
    # ...then the operator sends another message — it supersedes the owed resume.
    assert {:ok, :queued, 1} = Queue.enqueue(id, "operator-2")

    finish_turn(turn1)

    # The queued operator message runs next, NOT an auto-resume turn.
    assert_receive {:turn_started, "operator-2", turn2}, 1_000

    # And once that drains, no auto-resume is owed (the operator cleared it).
    finish_turn(turn2)
    refute_receive {:turn_started, _prompt, _}, 200
    assert %{busy?: false, depth: 0} = Queue.snapshot(id)
  end

  test "with auto-resume disabled, a mid-turn worker return enqueues nothing" do
    # config/test.exs ships auto_resume_on_worker_return: false (no enable here).
    {id, pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, _} = Queue.enqueue(id, "operator")
    assert_receive {:turn_started, "operator", turn}, 1_000

    send(pid, {:worker_terminal, %{name: "w1", ok?: true}})
    finish_turn(turn)

    refute_receive {:turn_started, _prompt, _}, 200
    assert %{busy?: false, depth: 0} = Queue.snapshot(id)
  end

  test "duplicate worker_id signals are deduped to a single resume (issue holding-pattern-duplicate-resumes)" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    # The queue is idle — first signal fires the resume immediately.
    worker_id = Ecto.UUID.generate()
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "documenter", ok?: true}})
    assert_receive {:turn_started, prompt, turn}, 1_000
    assert prompt =~ "documenter"

    # Duplicate signal for the same worker while the resume turn is in flight.
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "documenter", ok?: true}})
    finish_turn(turn)

    # No second resume — the duplicate was dropped.
    refute_receive {:turn_started, _prompt, _}, 200
    assert %{busy?: false, depth: 0} = Queue.snapshot(id)
  end

  test "duplicate signals across multiple turns are all deduped" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    # Simulate 4 fires for the same worker (like a 4-step ADW emitting per-step dones).
    worker_id = Ecto.UUID.generate()
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "adw", ok?: true}})
    assert_receive {:turn_started, _, turn1}, 1_000

    # Fires 2-4 arrive during turn1 — all deduped (no pending is set).
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "adw", ok?: true}})
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "adw", ok?: true}})
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "adw", ok?: true}})
    finish_turn(turn1)

    # Queue drains cleanly — no pending owed and no more turns.
    refute_receive {:turn_started, _, _}, 200
    assert %{busy?: false, depth: 0} = Queue.snapshot(id)
  end

  test "operator message resets dedup so the same worker can trigger a fresh resume" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    worker_id = Ecto.UUID.generate()
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "w1", ok?: true}})
    assert_receive {:turn_started, _, turn1}, 1_000
    finish_turn(turn1)

    # Duplicate signal still suppressed within the same operator context.
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "w1", ok?: true}})
    refute_receive {:turn_started, _, _}, 100

    # Operator message resets the dedup context.
    assert {:ok, :started, _} = Queue.enqueue(id, "operator resets context")
    assert_receive {:turn_started, "operator resets context", turn2}, 1_000
    finish_turn(turn2)

    # Same worker returning again is now a fresh signal.
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "w1", ok?: true}})
    assert_receive {:turn_started, prompt, _turn3}, 1_000
    assert prompt =~ "w1"
  end

  test "an idle-flavored signal enqueues exactly one review-flavored resume when idle" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    worker_id = Ecto.UUID.generate()

    send(
      pid,
      {:worker_terminal, %{worker_id: worker_id, name: "mech-builder", ok?: true, idle?: true}}
    )

    assert_receive {:turn_started, prompt, turn}, 1_000
    # The idle flavor — review/harvest, NOT the generic "completed successfully".
    assert prompt =~ "mech-builder"
    assert prompt =~ "IDLE"
    assert prompt =~ "Review"
    refute prompt =~ "completed successfully"

    finish_turn(turn)
    refute_receive {:turn_started, _prompt, _}, 200
    assert %{busy?: false, depth: 0} = Queue.snapshot(id)
  end

  test "an idle-flavored mid-turn signal coalesces to one pending resume" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, _} = Queue.enqueue(id, "operator")
    assert_receive {:turn_started, "operator", turn}, 1_000

    worker_id = Ecto.UUID.generate()
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "idler", ok?: true, idle?: true}})
    refute_receive {:turn_started, _prompt, _}, 200

    finish_turn(turn)
    assert_receive {:turn_started, prompt, _resume}, 1_000
    assert prompt =~ "idler"
    assert prompt =~ "IDLE"
  end

  test "a holding signal is still routed to the holding resume, not the idle flavor" do
    enable_auto_resume()
    {_id, pid} = start_queue(controllable_starter(self()))

    worker_id = Ecto.UUID.generate()

    send(
      pid,
      {:worker_terminal,
       %{
         worker_id: worker_id,
         name: "blocked-worker",
         ok?: true,
         holding?: true,
         holding_reason: "waiting on login"
       }}
    )

    assert_receive {:turn_started, prompt, _turn}, 1_000
    assert prompt =~ "blocked-worker"
    assert prompt =~ "HOLDING"
    refute prompt =~ "went IDLE"
  end

  test "a re-dispatched worker can re-engage again after a prior idle follow-up" do
    enable_auto_resume()
    {id, pid} = start_queue(controllable_starter(self()))

    worker_id = Ecto.UUID.generate()
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "w1", ok?: true, idle?: true}})
    assert_receive {:turn_started, _prompt, turn1}, 1_000
    finish_turn(turn1)

    # A duplicate idle signal within the same context is suppressed (dedup).
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "w1", ok?: true, idle?: true}})
    refute_receive {:turn_started, _prompt, _}, 200

    # Re-dispatch the SAME worker — a fresh work cycle clears it from the dedup set.
    redispatched = spawn(fn -> receive(do: (:stop -> :ok)) end)
    :ok = Queue.monitor_worker(id, worker_id, redispatched)

    # Its next idle/terminal can re-engage the orchestrator again.
    send(pid, {:worker_terminal, %{worker_id: worker_id, name: "w1", ok?: true, idle?: true}})
    assert_receive {:turn_started, prompt, _turn2}, 1_000
    assert prompt =~ "w1"
    assert prompt =~ "IDLE"

    send(redispatched, :stop)
  end

  test "different worker_ids are not deduped" do
    enable_auto_resume()
    {_id, pid} = start_queue(controllable_starter(self()))

    # Worker A returns.
    send(pid, {:worker_terminal, %{worker_id: "worker-a", name: "a", ok?: true}})
    assert_receive {:turn_started, prompt_a, turn_a}, 1_000
    assert prompt_a =~ "a"
    finish_turn(turn_a)

    # Worker B returns (different id) — NOT a duplicate.
    send(pid, {:worker_terminal, %{worker_id: "worker-b", name: "b", ok?: true}})
    assert_receive {:turn_started, prompt_b, _turn_b}, 1_000
    assert prompt_b =~ "b"
  end
end
