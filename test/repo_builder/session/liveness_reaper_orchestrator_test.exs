defmodule RepoBuilder.Session.LivenessReaperOrchestratorTest do
  @moduledoc """
  Issue orchestrator-stuck (backstop, out-of-process): the `LivenessReaper`'s second
  sweep pass over the `orchestrators` table. An orchestrator turn that ends without a
  terminal reaching `Orchestrator.Server` (hard kill / brutal shutdown / node restart)
  wedges the row at `:running`; this pass finds a stuck `:running` orchestrator with no
  live turn and reconciles it to `:idle`, leaving live/within-grace/idle ones alone.

  Drives `LivenessReaper.sweep/0` directly. `async: false`: shared sandbox + the live
  `SessionRegistry`.
  """
  use RepoBuilder.SessionCase, async: false

  alias RepoBuilder.{Dashboard, Orchestrators, Repo}
  alias RepoBuilder.Orchestrator.Orchestrator
  alias RepoBuilder.Session.LivenessReaper

  # min_stale_ms in test config (config/test.exs) is 120_000.
  @stale_ms 120_000

  defp uniq, do: System.unique_integer([:positive])

  defp orchestrator do
    {:ok, orch} = Orchestrators.create(%{name: "orch-#{uniq()}", harness: "fake"})
    orch
  end

  # Force a row to `status` with an `updated_at` `age_ms` in the past (bypassing the
  # status changeset's automatic timestamp bump so the staleness is deterministic).
  defp force_status(orch, status, age_ms) do
    backdated = DateTime.add(DateTime.utc_now(), -age_ms, :millisecond)

    orch
    |> Ecto.Changeset.change(status: status, updated_at: backdated)
    |> Repo.update!()
  end

  setup do
    :ok = Dashboard.subscribe_events()
    :ok
  end

  test "reconciles a phantom :running orchestrator with no live turn to :idle" do
    orch = orchestrator()
    orch_id = orch.id
    force_status(orch, :running, @stale_ms + 60_000)

    assert LivenessReaper.sweep() == 1

    assert {:ok, %Orchestrator{status: :idle}} = Orchestrators.fetch(orch_id)
    assert_receive {:orchestrator_updated, %Orchestrator{id: ^orch_id, status: :idle}}, 2_000
  end

  test "leaves an orchestrator with a live \"orch-<id>-…\" session untouched" do
    orch = orchestrator()
    orch_id = orch.id
    force_status(orch, :running, @stale_ms + 60_000)

    # A live registered orchestrator turn session — mid-turn, must be left alone.
    {:ok, _} = Registry.register(RepoBuilder.SessionRegistry, "orch-#{orch_id}-#{uniq()}", nil)

    assert LivenessReaper.sweep() == 0
    assert {:ok, %Orchestrator{status: :running}} = Orchestrators.fetch(orch_id)
    refute_receive {:orchestrator_updated, %Orchestrator{id: ^orch_id}}, 300
  end

  test "leaves a :running orchestrator within the staleness grace untouched" do
    orch = orchestrator()
    orch_id = orch.id
    # Updated "now" — younger than min_stale_ms — guards the launch-window race.
    force_status(orch, :running, 0)

    assert LivenessReaper.sweep() == 0
    assert {:ok, %Orchestrator{status: :running}} = Orchestrators.fetch(orch_id)
    refute_receive {:orchestrator_updated, %Orchestrator{id: ^orch_id}}, 300
  end

  test "never touches an idle orchestrator" do
    orch = orchestrator()
    orch_id = orch.id
    force_status(orch, :idle, @stale_ms + 60_000)

    assert LivenessReaper.sweep() == 0
    assert {:ok, %Orchestrator{status: :idle}} = Orchestrators.fetch(orch_id)
  end
end
