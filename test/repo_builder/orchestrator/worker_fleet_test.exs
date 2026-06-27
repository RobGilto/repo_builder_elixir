defmodule RepoBuilder.Orchestrator.WorkerFleetTest do
  @moduledoc """
  The deterministic, token-free drive-loop fleet gate. `async: false`: shared sandbox +
  the live `SessionRegistry` (a live worker is simulated by registering the test process
  under the worker id, exactly as the `LivenessReaper` tests do).
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Agents
  alias RepoBuilder.Orchestrator.WorkerFleet
  alias RepoBuilder.Orchestrators

  @grace_ms 90_000

  setup do
    {:ok, orch} = Orchestrators.get_or_create_default()
    %{orch: orch}
  end

  defp create_worker(orch_id) do
    {:ok, worker} =
      Agents.create_worker(orch_id, %{
        "name" => "worker-#{System.unique_integer([:positive])}",
        "harness" => "fake"
      })

    worker
  end

  # Set status + heartbeat directly (one change so Ecto doesn't auto-bump anything else).
  defp set(worker, status, heartbeat_age_ms) do
    heartbeat = DateTime.add(DateTime.utc_now(), -heartbeat_age_ms, :millisecond)

    worker
    |> Ecto.Changeset.change(status: status, heartbeat_at: heartbeat)
    |> Repo.update!()
  end

  # Mark the worker's session process as live by registering the test pid under its id.
  defp register_live(worker_id) do
    {:ok, _} = Registry.register(RepoBuilder.SessionRegistry, worker_id, nil)
    :ok
  end

  test "no live workers => :empty (drivable)", %{orch: orch} do
    assert WorkerFleet.classify(orch.id) == :empty
    assert WorkerFleet.drivable?(orch.id)
  end

  test "a :holding worker with a live process => :active (not drivable)", %{orch: orch} do
    worker = create_worker(orch.id)
    set(worker, :holding, 0)
    register_live(worker.id)

    assert WorkerFleet.classify(orch.id) == :active
    refute WorkerFleet.drivable?(orch.id)
  end

  test "a :running worker with a live process AND fresh heartbeat => :active", %{orch: orch} do
    worker = create_worker(orch.id)
    set(worker, :running, div(@grace_ms, 2))
    register_live(worker.id)

    assert WorkerFleet.classify(orch.id) == :active
    refute WorkerFleet.drivable?(orch.id)
  end

  test "a :running worker with NO live process => :quiescent (drivable)", %{orch: orch} do
    worker = create_worker(orch.id)
    set(worker, :running, 0)
    # No register_live/1: the row says :running but the process is gone.

    assert WorkerFleet.classify(orch.id) == :quiescent
    assert WorkerFleet.drivable?(orch.id)
  end

  test "a live :running worker with a STALE heartbeat => :quiescent (drivable)", %{orch: orch} do
    worker = create_worker(orch.id)
    set(worker, :running, @grace_ms + 60_000)
    register_live(worker.id)

    assert WorkerFleet.classify(orch.id) == :quiescent
    assert WorkerFleet.drivable?(orch.id)
  end

  test "one progressing worker among quiescent ones => :active", %{orch: orch} do
    stale = create_worker(orch.id)
    set(stale, :running, @grace_ms + 60_000)
    register_live(stale.id)

    fresh = create_worker(orch.id)
    set(fresh, :running, 0)
    register_live(fresh.id)

    assert WorkerFleet.classify(orch.id) == :active
  end

  test "archived live workers are ignored => :empty", %{orch: orch} do
    worker = create_worker(orch.id)
    set(worker, :running, 0)
    register_live(worker.id)
    {:ok, _} = Agents.archive_agent(worker)

    assert WorkerFleet.classify(orch.id) == :empty
  end
end
