defmodule RepoBuilderWeb.OrchestratorFocusTest do
  @moduledoc """
  Focus discipline in the console: the autonomy panel renders a live `🎯 FOCUS` line for the
  orchestrator-level focus (`#orchestrator-focus`), updating live over the `ledger_updated`
  broadcast. Workstream-level focus is now carried in the workstream data but is not separately
  rendered in the ADWS swimlane view (the operator sees it via the goal-card summary strip).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Orchestrator.{Ledgers, Workstreams}
  alias RepoBuilder.Orchestrators

  defp default_orchestrator do
    {:ok, orch} = Orchestrators.get_or_create_default()
    orch
  end

  test "the autonomy panel renders the orchestrator-level focus live", %{conn: conn} do
    orch = default_orchestrator()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "ship it", definition_of_done: "green"})

    {:ok, view, _html} = live(conn, "/")

    # Unfocused: the hint shows, no focus line yet.
    assert has_element?(view, "#orchestrator-focus-hint")
    refute has_element?(view, "#orchestrator-focus")

    {:ok, _} = Ledgers.set_focus(orch.id, "land the focus gate")
    :ok = Dashboard.broadcast_ledger_updated(orch.id, Ledgers.view(orch.id))

    assert has_element?(view, "#orchestrator-focus")
    assert render(view) =~ "land the focus gate"
  end

  test "workstream broadcast updates the workstreams assign live", %{conn: conn} do
    orch = default_orchestrator()

    {:ok, ws} =
      Workstreams.create_workstream(orch.id, %{
        title: "Stream Alpha",
        goal: "g",
        definition_of_done: "d"
      })

    {:ok, ws} =
      Workstreams.plan_phases(orch.id, ws.id, [%{title: "Phase one"}])

    first_phase = List.first(ws.phases)

    {:ok, view, _html} = live(conn, "/")
    # Toggle to ADWS view to see the swimlane.
    render_click(view, "toggle_view")

    # Advance spec stage and broadcast — swimlane moves the card to implement.
    {:ok, _} = Workstreams.record_stage(orch.id, ws.id, %{stage: :spec, outcome: :passed})
    :ok = Dashboard.broadcast_workstreams(orch.id, Workstreams.list_records(orch.id))

    assert has_element?(view, "#swimlane-implement #phase-card-#{first_phase.id}")
  end
end
