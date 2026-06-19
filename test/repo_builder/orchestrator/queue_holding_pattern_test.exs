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
end
