defmodule RepoBuilder.Orchestrator.TurnIdleTimeoutTest do
  @moduledoc """
  Orchestrator turns get their own SHORTER idle watchdog than worker sessions
  (issue orch-stall). A byte-silent orchestrator turn beyond `:orchestrator`
  `turn_idle_ms` is treated as stalled: the existing session idle-timeout path emits
  `Event.Error{reason: :idle_timeout, retryable: true}`, the turn flushes `:error`
  and stops, and the queue is free to proceed — no operator nudge required.

  Test A proves a hung turn surfaces the idle timeout and recovers within the (short,
  test-overridden) window. Before the fix `Orchestrator.Server` passed no `idle_ms`,
  so the 100 ms override was ignored and the worker-grade 300 s default applied — the
  turn would NOT time out in 2 s and Test A would fail. Test B guards that a normal
  (completing) turn is unaffected.
  """
  use RepoBuilder.SessionCase, async: false

  import Mox

  alias RepoBuilder.Orchestrator.Server
  alias RepoBuilder.Orchestrators

  @mock RepoBuilder.Harness.Mock

  defp uniq, do: System.unique_integer([:positive])

  setup do
    on_exit(&drain_sessions/0)
    :ok
  end

  defp drain_sessions(attempts \\ 200) do
    case DynamicSupervisor.count_children(RepoBuilder.SessionSupervisor) do
      %{active: 0} -> :ok
      _ when attempts > 0 -> Process.sleep(20) && drain_sessions(attempts - 1)
      _ -> :ok
    end
  end

  # Override `turn_idle_ms` to a tiny value for the scope (restoring on exit) so the
  # short idle window fires in test time.
  defp override_turn_idle_ms(ms) do
    original = Application.fetch_env!(:repo_builder, :orchestrator)
    Application.put_env(:repo_builder, :orchestrator, Keyword.put(original, :turn_idle_ms, ms))
    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, original) end)
    :ok
  end

  # Point the orchestrating "fake" harness at `module`, PRESERVING `orchestrating: true`
  # (the base `register_harness/2` drops it) so the turn passes `ensure_orchestrating/1`.
  defp register_orchestrating_harness(key, module) do
    original = Application.fetch_env!(:repo_builder, :harnesses)
    entry = original |> Map.fetch!(key) |> Map.merge(%{module: module})
    Application.put_env(:repo_builder, :harnesses, Map.put(original, key, entry))
    on_exit(fn -> Application.put_env(:repo_builder, :harnesses, original) end)
    :ok
  end

  test "a hung orchestrator turn surfaces idle_timeout and recovers within the short window" do
    override_turn_idle_ms(200)
    register_orchestrating_harness("fake", @mock)

    # A hung child that emits nothing — the byte-idle watchdog is the only thing that
    # can end the turn (mirrors session/server_test.exs hung-child pattern).
    stub(@mock, :command, fn _ -> {"sleep", ["10"], [], %{harness: :fake}} end)
    stub(@mock, :normalize, fn _, _ -> :skip end)

    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake", model: "fake-model"})

    assert {:ok, pid, agent_id} = Server.start_turn(orch.id, "stall please")
    ref = Process.monitor(pid)
    subscribe(agent_id)

    # The (now sooner) idle expiry surfaces a retryable idle_timeout Error...
    assert_receive {:harness_event, %Event.Error{reason: :idle_timeout, retryable: true}}, 2_000
    # ...the turn process stops cleanly (freeing the queue, which monitors this pid)...
    assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

    # ...and the turn flushed status :error rather than sitting stuck at :running.
    assert eventually(fn ->
             {:ok, reloaded} = Orchestrators.fetch(orch.id)
             reloaded.status == :error
           end)
  end

  test "a normal completing turn is unaffected (no spurious idle_timeout)" do
    # Even with a short window, the real Fake harness streams frames that reset the
    # idle timer and reach Done — the regression guard.
    override_turn_idle_ms(200)

    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake", model: "fake-model"})

    assert {:ok, _pid, agent_id} = Server.start_turn(orch.id, "hello")
    subscribe(agent_id)

    assert_receive {:harness_event, %Event.Done{ok: true}}, 5_000

    assert eventually(fn ->
             {:ok, reloaded} = Orchestrators.fetch(orch.id)
             reloaded.status == :idle
           end)
  end

  defp eventually(fun, attempts \\ 200) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && eventually(fun, attempts - 1)
      true -> false
    end
  end
end
