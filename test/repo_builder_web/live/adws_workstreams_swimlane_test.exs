defmodule RepoBuilderWeb.AdwsWorkstreamsSwimlaneTest do
  @moduledoc """
  ADWS Phase Swimlane (adws-phase-swimlane): four-column Kanban board rendered
  inside the ADWS view. Tests mount, column layout, card placement by
  `current_stage`, live broadcast updates, and the `record_stage` quick-action
  operator event that advances a phase and re-renders its card in the next column.
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

  defp seed(orch, title, phases \\ [%{title: "Phase one"}, %{title: "Phase two"}]) do
    {:ok, ws} =
      Workstreams.create_workstream(orch.id, %{title: title, goal: "g", definition_of_done: "d"})

    {:ok, ws} =
      Workstreams.plan_phases(orch.id, ws.id, phases)

    ws
  end

  defp toggle_to_adws(view), do: render_click(view, "toggle_view")

  # ---- column presence --------------------------------------------------------

  test "four swimlane columns exist in ADWS view when workstreams present", %{conn: conn} do
    orch = default_orchestrator()
    _ws = seed(orch, "Work Alpha")

    {:ok, view, _html} = live(conn, "/")
    toggle_to_adws(view)

    assert has_element?(view, "#swimlane-spec")
    assert has_element?(view, "#swimlane-implement")
    assert has_element?(view, "#swimlane-test")
    assert has_element?(view, "#swimlane-review")
  end

  test "swimlane not rendered when no workstreams", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, view, _html} = live(conn, "/")
    toggle_to_adws(view)
    refute has_element?(view, "#workstreams-swimlane")
  end

  # ---- card placement by current_stage ----------------------------------------

  test "phase card appears in spec column at initial stage", %{conn: conn} do
    orch = default_orchestrator()
    ws = seed(orch, "Spec Work")
    first_phase = List.first(ws.phases)

    {:ok, view, _html} = live(conn, "/")
    toggle_to_adws(view)

    assert has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")
    refute has_element?(view, "#swimlane-implement #phase-card-#{first_phase.id}")
  end

  test "phase card moves to implement column after spec passed", %{conn: conn} do
    orch = default_orchestrator()
    ws = seed(orch, "Implement Work")
    first_phase = List.first(ws.phases)

    {:ok, view, _html} = live(conn, "/")
    toggle_to_adws(view)

    # Phase starts in spec.
    assert has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")

    # Advance via broadcast.
    {:ok, _} =
      Workstreams.record_stage(orch.id, ws.id, %{
        stage: :spec,
        outcome: :passed,
        artifact: "specs/impl.md"
      })

    :ok = Dashboard.broadcast_workstreams(orch.id, Workstreams.list_records(orch.id))

    assert has_element?(view, "#swimlane-implement #phase-card-#{first_phase.id}")
    refute has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")
  end

  test "phase card moves through implement→test→review columns", %{conn: conn} do
    orch = default_orchestrator()
    ws = seed(orch, "Pipeline Work")
    first_phase = List.first(ws.phases)

    {:ok, view, _html} = live(conn, "/")
    toggle_to_adws(view)

    advance = fn stage ->
      {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: stage, outcome: :passed})
      :ok = Dashboard.broadcast_workstreams(orch.id, Workstreams.list_records(orch.id))
    end

    advance.(:spec)
    assert has_element?(view, "#swimlane-implement #phase-card-#{first_phase.id}")

    advance.(:implement)
    assert has_element?(view, "#swimlane-test #phase-card-#{first_phase.id}")

    advance.(:test)
    assert has_element?(view, "#swimlane-review #phase-card-#{first_phase.id}")
  end

  # ---- record_stage quick-action event ----------------------------------------

  test "record_stage event advances phase and updates swimlane", %{conn: conn} do
    orch = default_orchestrator()
    ws = seed(orch, "Quick Action Work")
    first_phase = List.first(ws.phases)

    {:ok, view, _html} = live(conn, "/")
    toggle_to_adws(view)

    assert has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")

    # Drive the quick-action button click.
    render_click(view, "record_stage", %{
      "ref" => ws.id,
      "stage" => "spec",
      "outcome" => "passed"
    })

    assert has_element?(view, "#swimlane-implement #phase-card-#{first_phase.id}")
    refute has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")
  end

  test "record_stage event with failed outcome keeps card in same column", %{conn: conn} do
    orch = default_orchestrator()
    ws = seed(orch, "Failed Stage Work")
    first_phase = List.first(ws.phases)

    {:ok, view, _html} = live(conn, "/")
    toggle_to_adws(view)

    assert has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")

    render_click(view, "record_stage", %{
      "ref" => ws.id,
      "stage" => "spec",
      "outcome" => "failed"
    })

    # A failed stage retries; card stays in the spec column.
    assert has_element?(view, "#swimlane-spec #phase-card-#{first_phase.id}")
  end

  # ---- multi-workstream layout ------------------------------------------------

  test "phases from multiple workstreams appear in correct columns", %{conn: conn} do
    orch = default_orchestrator()
    ws_a = seed(orch, "Stream A", [%{title: "A Phase"}])
    ws_b = seed(orch, "Stream B", [%{title: "B Phase"}])

    phase_a = List.first(ws_a.phases)

    # Advance ws_b's phase to implement.
    {:ok, _} =
      Workstreams.record_stage(orch.id, ws_b.id, %{
        stage: :spec,
        outcome: :passed,
        artifact: "specs/b.md"
      })

    # Reload ws_b to get updated phase data.
    {:ok, ws_b_updated} = Workstreams.get_workstream(orch.id, ws_b.id)
    phase_b_updated = List.first(ws_b_updated.phases)

    {:ok, view, _html} = live(conn, "/")
    toggle_to_adws(view)

    # Stream A phase 1 is in spec.
    assert has_element?(view, "#swimlane-spec #phase-card-#{phase_a.id}")
    # Stream B phase 1 is in implement.
    assert has_element?(view, "#swimlane-implement #phase-card-#{phase_b_updated.id}")
  end
end
