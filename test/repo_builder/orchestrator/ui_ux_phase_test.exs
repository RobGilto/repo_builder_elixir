defmodule RepoBuilder.Orchestrator.UiUxPhaseTest do
  @moduledoc """
  Iterative UI/UX polish phase (orchestrator-iterative-ui-ux-polish-phase, Phase 3): a
  `:ui_ux` phase carries `kind`/`surface`/`iteration`, its failed review is BOUNDED polish
  (increments `iteration` and re-enters the fix branch until the cap, then auto-completes at
  MVP), and a default `:backend` phase behaves byte-for-byte as before.
  """
  use RepoBuilder.DataCase, async: false

  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.Orchestrators

  defp orchestrator do
    {:ok, orch} =
      Orchestrators.create(%{name: "orch-#{System.unique_integer([:positive])}", harness: "fake"})

    orch
  end

  defp seed(orch) do
    {:ok, ws} =
      Workstreams.create_workstream(orch.id, %{title: "Polish UI", goal: "ship a decent MVP"})

    ws
  end

  defp current_phase(orch, ref) do
    {:ok, record} = Workstreams.get_workstream(orch.id, ref)
    Enum.find(record.phases, &(&1.position == record.current_phase_position))
  end

  defp advance_to_review(orch, ref) do
    for stage <- [:spec, :implement, :test] do
      {:ok, _} = Workstreams.record_stage(orch.id, ref, %{stage: stage, outcome: :passed})
    end
  end

  describe "plan_phases with kind/surface" do
    test "persists a :ui_ux phase with its surface, defaulting others to :backend" do
      orch = orchestrator()
      ws = seed(orch)

      {:ok, _} =
        Workstreams.plan_phases(orch.id, ws.id, [
          %{title: "Backend", description: "api"},
          %{title: "Web polish", description: "ui", kind: :ui_ux, surface: :web}
        ])

      {:ok, record} = Workstreams.get_workstream(orch.id, ws.id)
      [backend, uiux] = record.phases

      assert backend.kind == :backend
      assert backend.surface == nil
      assert backend.iteration == 0
      assert uiux.kind == :ui_ux
      assert uiux.surface == :web
    end
  end

  describe ":ui_ux review→fix iteration cap" do
    setup do
      Application.put_env(
        :repo_builder,
        :orchestrator,
        Keyword.put(Application.get_env(:repo_builder, :orchestrator, []), :ui_iteration_cap, 3)
      )

      :ok
    end

    test "a failed review increments iteration and re-enters the fix branch under the cap" do
      orch = orchestrator()
      ws = seed(orch)

      {:ok, _} =
        Workstreams.plan_phases(orch.id, ws.id, [
          %{title: "Web polish", kind: :ui_ux, surface: :web}
        ])

      advance_to_review(orch, ws.id)

      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :review, outcome: :failed})
      phase = current_phase(orch, ws.id)

      assert phase.iteration == 1
      assert phase.status == :running
      assert phase.current_stage == :review
    end

    test "auto-completes at the cap (MVP reached) instead of blocking" do
      orch = orchestrator()
      ws = seed(orch)

      {:ok, _} =
        Workstreams.plan_phases(orch.id, ws.id, [
          %{title: "Web polish", kind: :ui_ux, surface: :web}
        ])

      advance_to_review(orch, ws.id)

      for _ <- 1..3 do
        {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :review, outcome: :failed})
      end

      {:ok, record} = Workstreams.get_workstream(orch.id, ws.id)
      phase = List.first(record.phases)

      assert phase.iteration == 3
      assert phase.status == :done
      assert phase.current_stage == :done
      # Auto-complete, NOT blocked — the workstream is never stalled by cosmetic iteration.
      assert record.status != :blocked
    end

    test "a passed review completes the :ui_ux phase without incrementing iteration" do
      orch = orchestrator()
      ws = seed(orch)

      {:ok, _} =
        Workstreams.plan_phases(orch.id, ws.id, [
          %{title: "Web polish", kind: :ui_ux, surface: :web}
        ])

      advance_to_review(orch, ws.id)
      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :review, outcome: :passed})

      {:ok, record} = Workstreams.get_workstream(orch.id, ws.id)
      phase = List.first(record.phases)

      assert phase.iteration == 0
      assert phase.status == :done
    end

    test "auto-completing a :ui_ux phase promotes the next phase" do
      orch = orchestrator()
      ws = seed(orch)

      {:ok, _} =
        Workstreams.plan_phases(orch.id, ws.id, [
          %{title: "Web polish", kind: :ui_ux, surface: :web},
          %{title: "Tui polish", kind: :ui_ux, surface: :tui}
        ])

      advance_to_review(orch, ws.id)

      for _ <- 1..3 do
        {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :review, outcome: :failed})
      end

      {:ok, record} = Workstreams.get_workstream(orch.id, ws.id)
      assert record.current_phase_position == 2
      assert Enum.at(record.phases, 1).status == :running
    end
  end

  describe "backend regression (default kind)" do
    test "a backend phase's failed review still escalates to :blocked at the stall limit" do
      orch = orchestrator()
      ws = seed(orch)

      {:ok, _} = Workstreams.plan_phases(orch.id, ws.id, [%{title: "Backend only"}])
      advance_to_review(orch, ws.id)

      for _ <- 1..3 do
        {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :review, outcome: :failed})
      end

      {:ok, record} = Workstreams.get_workstream(orch.id, ws.id)
      assert record.status == :blocked
      assert List.first(record.phases).iteration == 0
    end
  end
end
