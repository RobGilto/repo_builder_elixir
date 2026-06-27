defmodule RepoBuilder.Orchestrator.DriverFleetGateTest do
  @moduledoc """
  The deterministic-worker-fleet gate + per-orchestrator cooldown on the autonomous drive
  loop (deterministic-worker-fleet-gate). A real `Driver` + real `Queue` with an injected
  starter (mirroring `DriverTest`), so the loop is fully deterministic and the test owns the
  clock via `Driver.tick/0`. `async: false`: shared sandbox + the singleton Driver + the live
  `SessionRegistry`.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Agents
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

  # A real Queue whose injected starter runs `turn_fn` then returns a dead pid so the
  # Queue's monitor advances it back to idle (identical to DriverTest).
  defp queue_with(orch_id, turn_fn) do
    starter = fn oid, prompt ->
      _ = turn_fn.(oid, prompt)
      {:ok, spawn(fn -> :ok end), "orch-#{oid}-#{System.unique_integer([:positive])}"}
    end

    start_supervised!({Queue, orchestrator_id: orch_id, starter: starter}, id: {:queue, orch_id})
  end

  defp flush(queue), do: :sys.get_state(queue)

  # Make the orchestrator's fleet `:active`: a live `:running` worker with a fresh heartbeat.
  defp add_live_worker(orch_id) do
    {:ok, worker} =
      Agents.create_worker(orch_id, %{
        "name" => "worker-#{System.unique_integer([:positive])}",
        "harness" => "fake"
      })

    worker
    |> Ecto.Changeset.change(status: :running, heartbeat_at: DateTime.utc_now())
    |> Repo.update!()

    {:ok, _} = Registry.register(RepoBuilder.SessionRegistry, worker.id, nil)
    worker
  end

  test "an orchestrator with a live, progressing worker is NOT driven (fleet gate)" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})
    _queue = queue_with(orch.id, fn oid, _p -> Ledgers.record_progress(oid, %{}) end)

    add_live_worker(orch.id)

    assert Driver.tick() == 0
    # No drive turn ran, so no progress entry was recorded.
    assert Ledgers.latest_progress(orch.id) == nil
  end

  test "an orchestrator with no live workers IS driven (fleet :empty)" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

    queue =
      queue_with(orch.id, fn oid, _p ->
        Ledgers.record_progress(oid, %{"made_progress" => true})
      end)

    assert Driver.tick() == 1
    flush(queue)
    assert Ledgers.latest_progress(orch.id) != nil
  end

  test "an orchestrator with only quiescent (dead-process) workers IS driven" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

    queue =
      queue_with(orch.id, fn oid, _p ->
        Ledgers.record_progress(oid, %{"made_progress" => true})
      end)

    # A :running row with NO SessionRegistry process => :quiescent => drivable.
    {:ok, worker} =
      Agents.create_worker(orch.id, %{"name" => "ghost", "harness" => "fake"})

    worker |> Ecto.Changeset.change(status: :running) |> Repo.update!()

    assert Driver.tick() == 1
    flush(queue)
    assert Ledgers.latest_progress(orch.id) != nil
  end

  test "the per-orchestrator cooldown suppresses a too-soon second drive" do
    orch = create_orch()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})
    counter = start_supervised!({Agent, fn -> 0 end}, id: :drive_counter)

    queue =
      queue_with(orch.id, fn oid, _p ->
        Agent.update(counter, &(&1 + 1))
        Ledgers.record_progress(oid, %{"made_progress" => true})
      end)

    prev = Application.get_env(:repo_builder, :orchestrator, [])

    on_exit(fn -> Application.put_env(:repo_builder, :orchestrator, prev) end)

    # A large cooldown so the second immediate tick is throttled.
    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(prev, :min_drive_interval_ms, 600_000)
    )

    assert Driver.tick() == 1
    flush(queue)
    assert Agent.get(counter, & &1) == 1

    # Within the cooldown window: not driven again.
    assert Driver.tick() == 0
    flush(queue)
    assert Agent.get(counter, & &1) == 1

    # Drop the cooldown to 0: the next tick drives again.
    Application.put_env(
      :repo_builder,
      :orchestrator,
      Keyword.put(prev, :min_drive_interval_ms, 0)
    )

    assert Driver.tick() == 1
    flush(queue)
    assert Agent.get(counter, & &1) == 2
  end
end
