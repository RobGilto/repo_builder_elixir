defmodule RepoBuilderWeb.WorkstreamsPanelTest do
  @moduledoc """
  Workstreams are now shown as a Kanban swimlane board in the ADWS view
  (adws-phase-swimlane) rather than the bottom drawer panel. The old
  `#workstreams-panel` no longer exists; `#workstreams-swimlane` is the live
  render target. This file verifies the basic mount and live-update behaviour
  after the migration from the drawer panel.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Orchestrator.Workstreams
  alias RepoBuilder.Orchestrators

  defp default_orchestrator do
    {:ok, orch} = Orchestrators.get_or_create_default()
    orch
  end

  defp seed(orch, title) do
    {:ok, ws} =
      Workstreams.create_workstream(orch.id, %{title: title, goal: "g", definition_of_done: "d"})

    {:ok, ws} =
      Workstreams.plan_phases(orch.id, ws.id, [
        %{title: "Phase one"},
        %{title: "Phase two"}
      ])

    ws
  end

  test "workstreams swimlane renders in ADWS view with phase cards", %{conn: conn} do
    orch = default_orchestrator()
    ws = seed(orch, "Stream Alpha")
    first_phase = List.first(ws.phases)

    {:ok, view, _html} = live(conn, "/")

    # Toggle to ADWS view.
    view |> element("#adw-controls") |> render()
    render_click(view, "toggle_view")

    # The swimlane board renders when workstreams exist.
    assert has_element?(view, "#workstreams-swimlane")

    # The four column IDs are present.
    assert has_element?(view, "#swimlane-spec")
    assert has_element?(view, "#swimlane-implement")
    assert has_element?(view, "#swimlane-test")
    assert has_element?(view, "#swimlane-review")

    # Phase 1 is in :spec column (its initial current_stage).
    assert has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")
  end

  test "no workstreams-panel in drawer (old panel removed)", %{conn: conn} do
    orch = default_orchestrator()
    _ws = seed(orch, "Stream Beta")

    {:ok, view, _html} = live(conn, "/")

    refute has_element?(view, "#workstreams-panel")
  end

  test "updates the swimlane live on a broadcast record_stage change", %{conn: conn} do
    orch = default_orchestrator()
    ws = seed(orch, "Live Stream")
    first_phase = List.first(ws.phases)

    {:ok, view, _html} = live(conn, "/")
    render_click(view, "toggle_view")

    # Phase 1 starts in the spec column.
    assert has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")

    # Advance spec → implement, then broadcast.
    {:ok, _} =
      Workstreams.record_stage(orch.id, ws.id, %{
        stage: :spec,
        outcome: :passed,
        artifact: "specs/x.md"
      })

    :ok = Dashboard.broadcast_workstreams(orch.id, Workstreams.list_records(orch.id))

    # Phase card now appears in the implement column.
    assert has_element?(view, "#swimlane-implement #phase-card-#{first_phase.id}")
  end

  test "renders nothing when the orchestrator has no workstreams (back-compat)", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, view, _html} = live(conn, "/")
    render_click(view, "toggle_view")
    refute has_element?(view, "#workstreams-swimlane")
  end
end
