defmodule RepoBuilderWeb.GoalCardToggleTest do
  @moduledoc """
  The goal-card collapse toggle: the bottom orchestrator drawer (autonomy panel + Workstreams
  panel + queued messages) collapses and expands via `#toggle-goal-card`, and while collapsed a
  compact `#goal-card-summary` strip surfaces the current focus. Session-local state, mirroring the
  left-rail collapse toggle.
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

    {:ok, ws} =
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
    assert has_element?(view, "#workstream-#{ws.id}")
    assert render(view) =~ "▼"
    refute has_element?(view, "#goal-card-summary")

    # Collapse: the body is gone, the handle flips to ▲, and the summary surfaces the focus.
    render_click(element(view, "#toggle-goal-card"))

    refute has_element?(view, "#autonomy-panel")
    refute has_element?(view, "#workstream-#{ws.id}")
    assert has_element?(view, "#goal-card-summary")
    assert render(view) =~ "▲"
    assert render(view) =~ "land the collapse toggle"

    # Expand again: the body returns.
    render_click(element(view, "#toggle-goal-card"))

    assert has_element?(view, "#autonomy-panel")
    assert has_element?(view, "#workstreams-panel")
    refute has_element?(view, "#goal-card-summary")
  end

  test "no toggle handle renders for an empty orchestrator", %{conn: conn} do
    _orch = default_orchestrator()

    {:ok, view, _html} = live(conn, "/")

    refute has_element?(view, "#toggle-goal-card")
  end
end
