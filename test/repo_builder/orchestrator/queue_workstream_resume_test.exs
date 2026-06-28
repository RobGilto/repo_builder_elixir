defmodule RepoBuilder.Orchestrator.QueueWorkstreamResumeTest do
  @moduledoc """
  Spec-driven phased orchestration (orchestration-adw-loop): the Queue as a workstream
  scheduler — workstream-tagged return routing (a worker's terminal resumes the RIGHT
  scratchpad), the rehydrate-on-resume seed after `compact_self`, and graceful degradation at
  the admission gate. Drives the Queue with a controllable `:starter` so every transition is
  deterministic.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Orchestrator.Queue
  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.Orchestrators

  defp controllable_starter(test_pid) do
    fn _orchestrator_id, prompt ->
      turn = spawn(fn -> receive(do: (:stop -> :ok)) end)
      send(test_pid, {:turn_started, prompt, turn})
      {:ok, turn, "agent-#{System.unique_integer([:positive])}"}
    end
  end

  defp start_queue(id, starter) do
    start_supervised!({Queue, orchestrator_id: id, starter: starter})
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

  defp orchestrator do
    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    orch
  end

  defp workstream(orch, title) do
    {:ok, ws} =
      Workstreams.create_workstream(orch.id, %{title: title, goal: "g", definition_of_done: "d"})

    {:ok, ws} = Workstreams.plan_phases(orch.id, ws.id, [%{title: "Phase 1"}])
    ws
  end

  describe "workstream-tagged return routing" do
    test "a tagged worker's return resumes naming the right workstream" do
      enable_auto_resume()
      orch = orchestrator()
      a = workstream(orch, "Stream A")
      b = workstream(orch, "Stream B")
      pid = start_queue(orch.id, controllable_starter(self()))

      # Worker tagged to A returns (queue idle) → resume names Stream A, not B.
      send(pid, {:worker_terminal, %{name: "wA", ok?: true, workstream_id: a.id}})
      assert_receive {:turn_started, prompt_a, turn_a}, 1_000
      assert prompt_a =~ "Stream A"
      assert prompt_a =~ "WORKSTREAM:"
      refute prompt_a =~ "Stream B"
      finish_turn(turn_a)

      # An operator message resets the dedup context, then a worker tagged to B returns →
      # resume names Stream B.
      assert {:ok, :started, _} = Queue.enqueue(orch.id, "operator")
      assert_receive {:turn_started, "operator", op_turn}, 1_000
      send(pid, {:worker_terminal, %{name: "wB", ok?: true, workstream_id: b.id}})
      finish_turn(op_turn)
      assert_receive {:turn_started, prompt_b, _}, 1_000
      assert prompt_b =~ "Stream B"
    end

    test "an untagged worker return falls back to the generic resume (back-compat)" do
      enable_auto_resume()
      orch = orchestrator()
      _ws = workstream(orch, "Unrelated")
      pid = start_queue(orch.id, controllable_starter(self()))

      send(pid, {:worker_terminal, %{name: "w1", ok?: true}})
      assert_receive {:turn_started, prompt, _}, 1_000
      assert prompt =~ "w1"
      refute prompt =~ "WORKSTREAM:"
    end
  end

  describe "rehydrate-on-resume after compact_self" do
    test "request_compaction runs /compact then seeds a continuation with the workstream index" do
      orch = orchestrator()
      ws = workstream(orch, "Persisted Stream")
      _pid = start_queue(orch.id, controllable_starter(self()))

      # Idle → the /compact turn starts immediately.
      assert :ok = Queue.request_compaction(orch.id)
      assert_receive {:turn_started, "/compact", compact_turn}, 1_000

      # When it drains, the continuation turn is seeded with the rehydration index.
      finish_turn(compact_turn)
      assert_receive {:turn_started, continuation, _}, 1_000
      assert continuation =~ "Memory rehydration"
      assert continuation =~ "Persisted Stream"
      assert continuation =~ ws.id
    end

    test "no active workstreams → /compact runs but no continuation is seeded (back-compat)" do
      orch = orchestrator()
      _pid = start_queue(orch.id, controllable_starter(self()))

      assert :ok = Queue.request_compaction(orch.id)
      assert_receive {:turn_started, "/compact", compact_turn}, 1_000
      finish_turn(compact_turn)
      refute_receive {:turn_started, _prompt, _}, 200
    end
  end

  describe "graceful degradation" do
    test "a starter that reports capacity exhaustion surfaces a clean error (no crash)" do
      id = Ecto.UUID.generate()
      starter = fn _id, _prompt -> {:error, :at_capacity} end
      _pid = start_queue(id, starter)

      assert {:error, :at_capacity} = Queue.enqueue(id, "operator")
      # The queue is still alive and idle — capacity pressure degraded gracefully.
      assert %{busy?: false, depth: 0} = Queue.snapshot(id)
    end
  end
end
