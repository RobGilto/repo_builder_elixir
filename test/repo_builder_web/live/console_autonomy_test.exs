defmodule RepoBuilderWeb.ConsoleAutonomyTest do
  @moduledoc """
  Self-healing Phase 6: the console autonomy panel — the goal/definition-of-done, lifecycle
  status, stall gauge, and latest progress render and update live on `ledger_updated`, and a loud
  "Escalated — awaiting human" banner with a one-click resume appears when the leader escalates.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Orchestrator.Ledgers
  alias RepoBuilder.Orchestrators

  defp default_orchestrator do
    {:ok, orch} = Orchestrators.get_or_create_default()
    orch
  end

  test "renders the goal panel and updates it live on ledger_updated", %{conn: conn} do
    orch = default_orchestrator()

    {:ok, _} =
      Ledgers.upsert_goal(orch.id, %{goal: "ship the feature", definition_of_done: "tests green"})

    {:ok, view, html} = live(conn, "/")

    # Seeded at mount.
    assert html =~ "ship the feature"
    assert html =~ "tests green"
    assert has_element?(view, "#autonomy-panel")

    # Live update via the ledger_updated broadcast.
    {:ok, _} =
      Ledgers.record_progress(orch.id, %{"made_progress" => true, "summary" => "wired the module"})

    :ok = Dashboard.broadcast_ledger_updated(orch.id, Ledgers.view(orch.id))

    assert render(view) =~ "wired the module"
  end

  test "shows the escalation banner with the holding reason and a resume button", %{conn: conn} do
    orch = default_orchestrator()
    {:ok, _} = Orchestrators.set_holding_reason(orch.id, "blocked on missing credentials")

    {:ok, view, html} = live(conn, "/")

    assert html =~ "Escalated — awaiting human"
    assert html =~ "blocked on missing credentials"
    assert has_element?(view, "#resume-orchestrator")
  end

  test "the resume button clears the escalation banner", %{conn: conn} do
    orch = default_orchestrator()
    {:ok, _} = Orchestrators.set_holding_reason(orch.id, "blocked")
    {:ok, _} = Ledgers.upsert_goal(orch.id, %{goal: "g", definition_of_done: "d"})

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#escalation-banner")

    view |> element("#resume-orchestrator") |> render_click()

    refute has_element?(view, "#escalation-banner")
    assert Orchestrators.holding_reason(elem(Orchestrators.fetch(orch.id), 1)) == nil
  end
end
