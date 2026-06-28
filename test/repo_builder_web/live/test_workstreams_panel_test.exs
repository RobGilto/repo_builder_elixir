defmodule RepoBuilderWeb.WorkstreamsPanelTest do
  @moduledoc """
  Spec-driven phased orchestration (orchestration-adw-loop): the console Workstreams panel —
  one row per workstream with its phases and four stage chips renders at mount, and updates
  live when a `record_stage` change is broadcast over PubSub (`workstreams_updated`).
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

  test "renders one row per workstream with phase + stage chips", %{conn: conn} do
    orch = default_orchestrator()
    a = seed(orch, "Stream Alpha")
    b = seed(orch, "Stream Beta")

    {:ok, view, html} = live(conn, "/")

    assert html =~ "Workstreams"
    assert html =~ "Stream Alpha"
    assert html =~ "Stream Beta"
    assert has_element?(view, "#workstream-#{a.id}")
    assert has_element?(view, "#workstream-#{b.id}")

    # Each phase renders its four stage chips; phase 1 spec is the current stage.
    assert has_element?(view, "#workstream-#{a.id}-phase-1-spec")
    assert has_element?(view, "#workstream-#{a.id}-phase-1-review")
    assert has_element?(view, ~s(#workstream-#{a.id}-phase-1-spec[data-stage-status="current"]))
  end

  test "updates the stage chip live on a broadcast record_stage change", %{conn: conn} do
    orch = default_orchestrator()
    ws = seed(orch, "Live Stream")

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, ~s(#workstream-#{ws.id}-phase-1-spec[data-stage-status="current"]))

    # Advance the spec stage, then broadcast the refreshed records (as the tools layer does).
    {:ok, _} =
      Workstreams.record_stage(orch.id, ws.id, %{
        stage: :spec,
        outcome: :passed,
        artifact: "specs/x.md"
      })

    :ok = Dashboard.broadcast_workstreams(orch.id, Workstreams.list_records(orch.id))

    # The spec chip is now passed and the current pointer moved to implement.
    assert has_element?(view, ~s(#workstream-#{ws.id}-phase-1-spec[data-stage-status="passed"]))

    assert has_element?(
             view,
             ~s(#workstream-#{ws.id}-phase-1-implement[data-stage-status="current"])
           )
  end

  test "renders nothing when the orchestrator has no workstreams (back-compat)", %{conn: conn} do
    _orch = default_orchestrator()
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#workstreams-panel")
  end
end
