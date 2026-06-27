defmodule RepoBuilder.Session.LivenessReaperTest do
  @moduledoc """
  Part B of issue worker-terminal: the periodic + boot liveness sweep that reconciles
  phantom `:running` workers (a worker `Session.Server` that died WITHOUT a terminal —
  hard kill / brutal shutdown / node restart — leaving the row wedged `:running` forever).

  Drives `LivenessReaper.sweep/0` directly (mirroring how OrphanReaper tests drive
  `reap_node/1`). `async: false`: shared sandbox + the live `SessionRegistry`.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Agents, Dashboard, Orchestrators, Repo}
  alias RepoBuilder.Agents.Agent
  alias RepoBuilder.Session.LivenessReaper

  # min_stale_ms in test config (config/test.exs) is 120_000.
  @stale_ms 120_000

  defp create_worker(orchestrator_id) do
    {:ok, worker} =
      Agents.create_worker(orchestrator_id, %{
        "name" => "w-#{System.unique_integer([:positive])}",
        "harness" => "claude",
        "provider" => "anthropic",
        "model" => "mock-model",
        "session_id" => "sess-#{System.unique_integer([:positive])}"
      })

    worker
  end

  # Force a row to `status` with an `updated_at` `age_ms` in the past (bypassing the
  # status changeset's automatic timestamp bump so the staleness is deterministic).
  defp force_status(agent, status, age_ms) do
    backdated = DateTime.add(DateTime.utc_now(), -age_ms, :millisecond)

    agent
    |> Ecto.Changeset.change(status: status, updated_at: backdated)
    |> Repo.update!()
  end

  # Force a worker into the "live-but-stale" shape the idle-demotion pass targets: `:running`
  # with both `updated_at` AND `heartbeat_at` `age_ms` in the past (setting both in one change
  # keeps Ecto from auto-bumping `updated_at`).
  defp force_live_stale(agent, age_ms) do
    backdated = DateTime.add(DateTime.utc_now(), -age_ms, :millisecond)

    agent
    |> Ecto.Changeset.change(status: :running, updated_at: backdated, heartbeat_at: backdated)
    |> Repo.update!()
  end

  # Set `heartbeat_at` to `age_ms` ago WITHOUT bumping `updated_at`.
  defp force_heartbeat(agent, age_ms) do
    backdated = DateTime.add(DateTime.utc_now(), -age_ms, :millisecond)

    agent
    |> Ecto.Changeset.change(heartbeat_at: backdated, updated_at: agent.updated_at)
    |> Repo.update!()
  end

  setup do
    {:ok, orch} = Orchestrators.get_or_create_default()
    :ok = Dashboard.subscribe_events()
    :ok = Dashboard.subscribe_orchestrator_workers(orch.id)
    %{orch: orch}
  end

  test "reconciles a phantom :running worker to :error and re-engages the orchestrator", %{
    orch: orch
  } do
    worker = create_worker(orch.id)
    worker_id = worker.id
    force_status(worker, :running, @stale_ms + 60_000)

    assert LivenessReaper.sweep() == 1

    assert %Agent{status: :error} = Agents.get_agent(worker_id)
    assert_receive {:agent_updated, %Agent{id: ^worker_id, status: :error}}, 2_000

    assert_receive {:worker_terminal, %{worker_id: ^worker_id, ok?: false, holding?: false}},
                   2_000
  end

  test "leaves a worker with a live session process untouched", %{orch: orch} do
    worker = create_worker(orch.id)
    worker_id = worker.id
    force_status(worker, :running, @stale_ms + 60_000)

    # Register a dummy process under the worker's id — a live, mid-turn worker.
    {:ok, _} = Registry.register(RepoBuilder.SessionRegistry, worker_id, nil)

    assert LivenessReaper.sweep() == 0
    assert %Agent{status: :running} = Agents.get_agent(worker_id)
    refute_receive {:worker_terminal, %{worker_id: ^worker_id}}, 300
  end

  test "leaves a :running worker within the staleness grace untouched", %{orch: orch} do
    worker = create_worker(orch.id)
    worker_id = worker.id
    # Updated "now" — younger than min_stale_ms — guards the optimistic-write race.
    force_status(worker, :running, 0)

    assert LivenessReaper.sweep() == 0
    assert %Agent{status: :running} = Agents.get_agent(worker_id)
    refute_receive {:worker_terminal, %{worker_id: ^worker_id}}, 300
  end

  test "never touches an idle agent", %{orch: orch} do
    worker = create_worker(orch.id)
    worker_id = worker.id
    force_status(worker, :idle, @stale_ms + 60_000)

    assert LivenessReaper.sweep() == 0
    assert %Agent{status: :idle} = Agents.get_agent(worker_id)
  end

  test "demotes a live-but-stale :running worker to :idle (not :error)", %{orch: orch} do
    worker = create_worker(orch.id)
    worker_id = worker.id
    force_live_stale(worker, @stale_ms + 60_000)

    # A LIVE session process: the phantom pass leaves it alone (it's not dead); the
    # idle-demotion pass softens it to :idle while it stays alive — no :error, no terminal.
    {:ok, _} = Registry.register(RepoBuilder.SessionRegistry, worker_id, nil)

    assert LivenessReaper.sweep() == 1
    assert %Agent{status: :idle} = Agents.get_agent(worker_id)
    assert_receive {:agent_updated, %Agent{id: ^worker_id, status: :idle}}, 2_000
    refute_receive {:worker_terminal, %{worker_id: ^worker_id}}, 300
  end

  test "leaves a live :running worker with a FRESH heartbeat untouched", %{orch: orch} do
    worker = create_worker(orch.id)
    worker_id = worker.id
    # Old updated_at (so the phantom pass would consider it) but a RECENT heartbeat: the
    # idle pass must not demote a worker that is actively making progress.
    worker = force_status(worker, :running, @stale_ms + 60_000)
    force_heartbeat(worker, 0)
    {:ok, _} = Registry.register(RepoBuilder.SessionRegistry, worker_id, nil)

    assert LivenessReaper.sweep() == 0
    assert %Agent{status: :running} = Agents.get_agent(worker_id)
  end

  test "reconciles a phantom with no orchestrator_id but fires no worker-terminal", %{orch: orch} do
    worker = create_worker(orch.id)
    worker_id = worker.id

    worker
    |> Ecto.Changeset.change(orchestrator_id: nil)
    |> Repo.update!()
    |> force_status(:running, @stale_ms + 60_000)

    assert LivenessReaper.sweep() == 1
    assert %Agent{status: :error} = Agents.get_agent(worker_id)
    assert_receive {:agent_updated, %Agent{id: ^worker_id, status: :error}}, 2_000
    refute_receive {:worker_terminal, %{worker_id: ^worker_id}}, 300
  end
end
