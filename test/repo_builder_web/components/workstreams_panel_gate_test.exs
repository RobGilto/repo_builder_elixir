defmodule RepoBuilderWeb.Components.WorkstreamsPanelGateTest do
  @moduledoc """
  The Workstreams panel renders a per-phase QUALITY-GATE strip (quality-gate-plugins,
  Phase 4): five dots (format · lint · type · test · mutation) sourced from the recorded
  GateResult on the phase's `test` stage — a red type stage renders a red type dot, a green
  gate renders all-green. Assertions target the stable DOM IDs.
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
      position: 1,
      title: "Phase one",
      description: nil,
      definition_of_done: nil,
      spec_path: nil,
      status: :running,
      current_stage: :test,
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
    render_component(&ConsoleComponents.workstreams_panel/1, workstreams: [ws], context_tokens: 0)
  end

  test "renders a red type dot for a phase with a red type stage" do
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

    assert html =~ ~s(id="workstream-ws-1-phase-1-gate")
    assert html =~ ~s(data-gate-green="false")
    # The type dot is red (failed); format/lint green.
    assert html =~ ~r/id="workstream-ws-1-phase-1-gate-type"[^>]*data-gate-status="failed"/
    assert html =~ ~r/gate-format"[^>]*data-gate-status="passed"/
  end

  test "renders an all-green gate strip" do
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

    assert html =~ ~s(data-gate-green="true")
    assert html =~ ~r/gate-type"[^>]*data-gate-status="passed"/
    assert html =~ ~r/gate-test"[^>]*data-gate-status="passed"/
    # `type` folds in `type-coverage`.
    assert html =~ ~s(data-gate-stage="type")
  end

  test "omits the gate strip when the phase has no recorded gate" do
    ws = workstream([phase(%{})])
    html = render_ws(ws)

    refute html =~ ~s(id="workstream-ws-1-phase-1-gate")
  end
end
