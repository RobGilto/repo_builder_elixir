defmodule RepoBuilder.Orchestrator.QueueTest do
  @moduledoc """
  Unit tests for the per-orchestrator FIFO turn queue state machine (issue
  message-queue). A pluggable `:starter` makes the busy/idle transitions fully
  deterministic — each "turn" is a controllable process the test holds and exits on
  demand, standing in for the real per-turn `Orchestrator.Server`.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Orchestrator.Queue

  # A starter that spawns a controllable "turn" process, notifies the test of the
  # started prompt + pid, and returns the {pid, agent_id} the queue monitors. Send the
  # pid `:stop` to simulate the turn finishing (its :DOWN advances the queue).
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

  test "an idle enqueue starts a turn immediately" do
    {id, _pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, "agent-go"} = Queue.enqueue(id, "go")
    assert_receive {:turn_started, "go", _turn}, 1_000

    assert %{busy?: true, depth: 0} = Queue.snapshot(id)
  end

  test "enqueue while busy queues instead of starting a second turn" do
    {id, _pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, _} = Queue.enqueue(id, "first")
    assert_receive {:turn_started, "first", _turn}, 1_000

    assert {:ok, :queued, 1} = Queue.enqueue(id, "second")
    # No second turn started while the first is in flight.
    refute_receive {:turn_started, "second", _}, 200

    assert %{busy?: true, depth: 1, queued: [%{preview: "second"}]} = Queue.snapshot(id)
  end

  test "the head of the FIFO is dequeued and started when the in-flight turn exits" do
    {id, _pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, _} = Queue.enqueue(id, "p1")
    assert_receive {:turn_started, "p1", turn1}, 1_000
    assert {:ok, :queued, 1} = Queue.enqueue(id, "p2")
    assert {:ok, :queued, 2} = Queue.enqueue(id, "p3")

    finish_turn(turn1)
    assert_receive {:turn_started, "p2", turn2}, 1_000

    finish_turn(turn2)
    assert_receive {:turn_started, "p3", _turn3}, 1_000

    assert %{busy?: true, depth: 0} = Queue.snapshot(id)
  end

  test "cancel removes a queued item; a missing id returns {:error, :not_found}" do
    {id, _pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, _} = Queue.enqueue(id, "first")
    assert_receive {:turn_started, "first", _turn}, 1_000
    assert {:ok, :queued, 1} = Queue.enqueue(id, "second")

    %{queued: [%{id: item_id}]} = Queue.snapshot(id)

    assert {:ok, %{depth: 0, queued: []}} = Queue.cancel(id, item_id)
    assert {:error, :not_found} = Queue.cancel(id, "nope")
  end

  test "enqueue past max_queue_depth is rejected with a tagged error" do
    original = Application.get_env(:repo_builder, :orchestrator)
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)
    Application.put_env(:repo_builder, :orchestrator, Keyword.put(original, :max_queue_depth, 2))

    {id, _pid} = start_queue(controllable_starter(self()))

    assert {:ok, :started, _} = Queue.enqueue(id, "first")
    assert_receive {:turn_started, "first", _turn}, 1_000
    assert {:ok, :queued, 1} = Queue.enqueue(id, "q1")
    assert {:ok, :queued, 2} = Queue.enqueue(id, "q2")
    assert {:error, :queue_full} = Queue.enqueue(id, "overflow")
  end

  test "a worker-terminal signal does nothing when auto-resume is disabled" do
    # config/test.exs ships auto_resume_on_worker_return: false.
    {id, pid} = start_queue(controllable_starter(self()))

    send(pid, {:worker_terminal, %{worker_id: "w", name: "builder", ok?: true}})

    refute_receive {:turn_started, _prompt, _turn}, 200
    assert %{busy?: false, depth: 0} = Queue.snapshot(id)
  end

  test "with auto-resume enabled, a worker return engages one idle resume turn" do
    original = Application.get_env(:repo_builder, :orchestrator)
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(original, :auto_resume_on_worker_return, true)
    )

    {_id, pid} = start_queue(controllable_starter(self()))

    send(pid, {:worker_terminal, %{worker_id: "w", name: "builder", ok?: true}})

    assert_receive {:turn_started, prompt, _turn}, 1_000
    assert prompt =~ "builder"
    assert prompt =~ "Review"
  end

  test "operator work suppresses the auto-resume holding pattern" do
    original = Application.get_env(:repo_builder, :orchestrator)
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)

    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(original, :auto_resume_on_worker_return, true)
    )

    {id, pid} = start_queue(controllable_starter(self()))

    # Busy with operator work: a worker-return signal must NOT start a resume turn.
    assert {:ok, :started, _} = Queue.enqueue(id, "operator")
    assert_receive {:turn_started, "operator", _turn}, 1_000

    # The operator turn was already consumed above; no further turn must start.
    send(pid, {:worker_terminal, %{worker_id: "w", name: "builder", ok?: true}})
    refute_receive {:turn_started, _prompt, _}, 200
  end

  test "every state change broadcasts a queue snapshot to the console topic" do
    {id, _pid} = start_queue(controllable_starter(self()))
    :ok = Dashboard.subscribe_orchestrator_queue(id)

    assert {:ok, :started, _} = Queue.enqueue(id, "go")
    assert_receive {:orchestrator_queue, ^id, %{busy?: true}}, 1_000

    assert {:ok, :queued, 1} = Queue.enqueue(id, "next")
    assert_receive {:orchestrator_queue, ^id, %{depth: 1}}, 1_000
  end
end
