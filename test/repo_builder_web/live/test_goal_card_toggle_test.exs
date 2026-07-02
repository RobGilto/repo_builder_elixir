defmodule RepoBuilderWeb.GoalCardToggleTest do
  @moduledoc """
  The goal-card collapse toggle: the bottom orchestrator drawer (autonomy panel + queued
  messages) collapses and expands via `#toggle-goal-card`, and while collapsed a compact
  `#goal-card-summary` strip surfaces the current focus. Workstreams are now shown in the ADWS
  view swimlane (adws-phase-swimlane), not the drawer — but an open workstream still triggers the
  goal-card toggle to appear (via `goal_card_present?/1`).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Orchestrator.{Ledgers, Workstreams}
  alias RepoBuilder.Orchestrators

  defp default_orchestrator do
    {:ok, orch} = Orchestrators.get_or_create_default()
    orch
  end

  test "collapses and expands the goal card, surfacing the focus while collapsed", %{conn: conn} do
    orch = default_orchestrator()
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "ship it", definition_of_done: "green"})
    {:ok, _} = Ledgers.set_focus(orch.id, "land the collapse toggle")

    {:ok, _ws} =
      Workstreams.create_workstream(orch.id, %{
        title: "Stream Alpha",
        goal: "g",
        definition_of_done: "d"
      })

    {:ok, view, _html} = live(conn, "/")

    # Expanded by default: the handle shows ▼ and the drawer body renders.
    assert has_element?(view, "#toggle-goal-card")
    assert has_element?(view, "#autonomy-panel")
    assert has_element?(view, "#orchestrator-focus")
    assert render(view) =~ "▼"
    refute has_element?(view, "#goal-card-summary")

    # Collapse: the body is gone, the handle flips to ▲, and the summary surfaces the focus.
    render_click(element(view, "#toggle-goal-card"))

    refute has_element?(view, "#autonomy-panel")
    assert has_element?(view, "#goal-card-summary")
    assert render(view) =~ "▲"
    assert render(view) =~ "land the collapse toggle"

    # Expand again: the body returns.
    render_click(element(view, "#toggle-goal-card"))

    assert has_element?(view, "#autonomy-panel")
    refute has_element?(view, "#goal-card-summary")
  end

  test "goal card toggle appears when an open workstream exists", %{conn: conn} do
    orch = default_orchestrator()

    {:ok, _ws} =
      Workstreams.create_workstream(orch.id, %{
        title: "Stream Beta",
        goal: "g",
        definition_of_done: "d"
      })

    {:ok, view, _html} = live(conn, "/")

    # A workstream alone (no ledger) still triggers the goal-card toggle.
    assert has_element?(view, "#toggle-goal-card")
  end

  test "no toggle handle renders for an empty orchestrator", %{conn: conn} do
    _orch = default_orchestrator()

    {:ok, view, _html} = live(conn, "/")

    refute has_element?(view, "#toggle-goal-card")
  end
end
