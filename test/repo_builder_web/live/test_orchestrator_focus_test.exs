defmodule RepoBuilderWeb.OrchestratorFocusTest do
  @moduledoc """
  Focus discipline in the console (two levels): the autonomy panel renders a live
  `🎯 FOCUS` line for the orchestrator-level focus (`#orchestrator-focus`), and each Workstreams
  panel row renders its own `🎯 FOCUS` line (`#workstream-<id>-focus`), both updating live over
  the existing `ledger_updated` / `workstreams` broadcasts.
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

  test "each workstream row renders its own focus live", %{conn: conn} do
    orch = default_orchestrator()

    {:ok, ws} =
      Workstreams.create_workstream(orch.id, %{
        title: "Stream Alpha",
        goal: "g",
        definition_of_done: "d"
      })

    {:ok, view, _html} = live(conn, "/")

    refute has_element?(view, "#workstream-#{ws.id}-focus")
    assert has_element?(view, "#workstream-#{ws.id}-focus-hint")

    {:ok, _} = Workstreams.set_focus(orch.id, ws.id, "wire phase 2 spec")
    :ok = Dashboard.broadcast_workstreams(orch.id, Workstreams.list_records(orch.id))

    assert has_element?(view, "#workstream-#{ws.id}-focus")
    assert render(view) =~ "wire phase 2 spec"
  end
end
