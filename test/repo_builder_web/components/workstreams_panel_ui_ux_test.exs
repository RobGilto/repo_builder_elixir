defmodule RepoBuilderWeb.Components.WorkstreamsPanelUiUxTest do
  @moduledoc """
  The workstreams swimlane board renders a `:ui_ux` phase distinctly
  (orchestrator-iterative-ui-ux-polish-phase): a surface + iteration N/cap badge, so the
  operator sees which surface is being polished and how close it is to the MVP cap.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RepoBuilderWeb.ConsoleComponents

  defp phase(overrides) do
    Map.merge(
      %{
        id: "ph-1",
        position: 1,
        title: "Web polish",
        description: nil,
        definition_of_done: nil,
        spec_path: nil,
        status: :running,
        current_stage: :review,
        kind: :backend,
        surface: nil,
        iteration: 0,
        stages: %{},
        completed: [],
        remaining: []
      },
      overrides
    )
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

  test "renders a surface + iteration badge for a :ui_ux phase" do
    ws = workstream([phase(%{kind: :ui_ux, surface: :web, iteration: 2})])

    html =
      render_component(&ConsoleComponents.workstreams_swimlane/1,
        orchestrator_id: "orch-1",
        workstreams: [ws],
        context_tokens: 0
      )

    assert html =~ ~s(data-phase-kind="ui_ux")
    assert html =~ "web 2/3"
  end

  test "does not render the UI/UX badge for a backend phase" do
    ws = workstream([phase(%{kind: :backend})])

    html =
      render_component(&ConsoleComponents.workstreams_swimlane/1,
        orchestrator_id: "orch-1",
        workstreams: [ws],
        context_tokens: 0
      )

    refute html =~ ~s(data-phase-kind="ui_ux")
  end
end
