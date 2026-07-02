defmodule RepoBuilderWeb.Components.WorkstreamsPanelGateTest do
  @moduledoc """
  The workstreams swimlane board (adws-phase-swimlane) replaced the old drawer panel.
  Quality-gate strips are no longer rendered in the console workstreams view — the swimlane
  focuses on phase placement (Spec→Implement→Test→Review columns) and quick-action buttons.
  These tests verify the swimlane renders correctly for phases with gate data in their stages
  map, without surfacing the gate dots.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RepoBuilderWeb.ConsoleComponents

  defp gate(stages, green?) do
    %{"green" => green?, "stages" => stages}
  end

  defp gate_stage(id, status), do: %{"stage_id" => id, "status" => status}

  defp phase(stages) do
    %{
      id: "ph-1",
      position: 1,
      title: "Phase one",
      description: nil,
      definition_of_done: nil,
      spec_path: nil,
      status: :running,
      current_stage: :review,
      kind: :backend,
      surface: nil,
      iteration: 0,
      stages: stages,
      completed: [],
      remaining: []
    }
  end

  defp workstream(phases) do
    %{
      id: "ws-1",
      title: "MVP",
      status: :running,
      next_action: nil,
      focus: nil,
      current_phase_position: 1,
      phases: phases
    }
  end

  defp render_ws(ws) do
    render_component(&ConsoleComponents.workstreams_swimlane/1,
      orchestrator_id: "orch-1",
      workstreams: [ws],
      context_tokens: 0
    )
  end

  test "phase card renders in review column regardless of gate data" do
    all_green =
      gate(
        [
          gate_stage("format", "passed"),
          gate_stage("lint", "passed"),
          gate_stage("type", "passed"),
          gate_stage("test", "passed")
        ],
        true
      )

    ws = workstream([phase(%{"test" => %{"status" => "passed", "gate" => all_green}})])
    html = render_ws(ws)

    assert html =~ ~s(id="phase-card-ph-1")
    assert html =~ ~s(id="swimlane-review")
  end

  test "gate strip is not rendered in the swimlane" do
    green_stages =
      gate(
        [
          gate_stage("format", "passed"),
          gate_stage("lint", "passed"),
          gate_stage("type", "failed"),
          gate_stage("test", "skipped")
        ],
        false
      )

    ws = workstream([phase(%{"test" => %{"status" => "failed", "gate" => green_stages}})])
    html = render_ws(ws)

    # Gate strip DOM IDs are no longer emitted.
    refute html =~ ~s(id="workstream-ws-1-phase-1-gate")
    refute html =~ ~s(data-gate-green)
  end
end
