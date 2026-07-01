defmodule RepoBuilderWeb.TestUnifiedAdwSwimlaneCardsTest do
  @moduledoc """
  LiveView test for the unified ADWS view (issue-unified-adw-swimlane-cards): the
  three old stacked blocks are replaced by one card list. Asserts ADW cards render a
  human-friendly title (never a UUID), `ADW: <type>`, a duration, per-step boxes with
  per-step status + the current step highlighted, the category-filter chip row, event
  squares with category icons, the click-to-open detail panel, that the standalone
  `#agent-lanes` roster block is gone, and the live title upgrade.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Dashboard, Workflows}
  alias RepoBuilder.Harness.Event

  defp uniq, do: System.unique_integer([:positive])

  defp seed_run(workflow_attrs) do
    {:ok, wf} =
      Workflows.create_workflow(
        Map.merge(
          %{
            name: "wf-#{uniq()}",
            type: "plan_build",
            steps: [
              %{"name" => "plan", "harness" => "fake", "on_success" => "build"},
              %{"name" => "build", "harness" => "fake", "on_success" => "done"}
            ]
          },
          workflow_attrs
        )
      )

    {:ok, run} =
      Workflows.create_run(%{workflow_id: wf.id, status: :running, current_step: "build"})

    {:ok, run} = Workflows.put_step_state(run, "plan", %{status: "succeeded"})
    {:ok, run} = Workflows.put_step_state(run, "build", %{status: "running"})
    {wf, run}
  end

  defp wait_render(view, substring, attempts \\ 100) do
    cond do
      render(view) =~ substring -> true
      attempts > 0 -> Process.sleep(20) && wait_render(view, substring, attempts - 1)
      true -> false
    end
  end

  defp to_adws(view), do: view |> element("#view-toggle") |> render_click()

  test "renders one unified ADW card with a human title, type, duration, and step boxes",
       %{conn: conn} do
    {_wf, run} = seed_run(%{name: "bug-fix-test"})

    {:ok, view, _html} = live(conn, ~p"/")
    to_adws(view)
    html = render(view)

    # One card per run (the old per-step swimlane id is preserved for back-compat).
    assert html =~ "workflow-#{run.id}"
    # Human-friendly title + the ADW type key line — and NOT the run UUID as the title.
    assert html =~ "bug-fix-test"
    assert html =~ "ADW: plan_build"
    refute html =~ run.id |> String.slice(0, 8) |> then(&"ADW #{&1}")

    # Per-step boxes carry per-step status; the current step ("build") is highlighted.
    assert html =~ ~s(data-step-status="succeeded")
    assert html =~ ~s(data-step-status="running")
    assert html =~ "cns-step-box--current"

    # Duration is shown; progress is 1/2 (one succeeded step).
    assert has_element?(view, ".cns-duration")
    assert html =~ "1/2"

    # The category-filter chip row is present; the old separate roster block is gone.
    assert has_element?(view, "#adw-cat-tool")
    refute html =~ ~s(id="agent-lanes")
  end

  test "title falls back to humanized type for a machine-looking name", %{conn: conn} do
    {_wf, run} = seed_run(%{name: "orch-adw-848273", type: "plan_build"})

    {:ok, view, _html} = live(conn, ~p"/")
    to_adws(view)
    html = render(view)

    # The machine-looking name is skipped; the humanized type is shown instead.
    assert html =~ "Plan Build"
    refute html =~ "orch-adw-848273"
    assert html =~ "workflow-#{run.id}"
  end

  test "title falls back to 'ADW <short>' when name is machine-like and type/step are absent",
       %{conn: conn} do
    {:ok, wf} = Workflows.create_workflow(%{name: "232sdasdasd", type: nil, steps: []})
    {:ok, run} = Workflows.create_run(%{workflow_id: wf.id, status: :running})

    {:ok, view, _html} = live(conn, ~p"/")
    to_adws(view)
    html = render(view)

    assert html =~ "ADW #{String.slice(run.id, 0, 8)}"
    refute html =~ "232sdasdasd"
  end

  test "event squares carry a category icon and open the detail panel on click",
       %{conn: conn} do
    {_wf, run} = seed_run(%{name: "square-test"})

    {:ok, view, _html} = live(conn, ~p"/")
    to_adws(view)

    # A tool event keyed to the run's `build` step lands as a square inside that step box
    # of the workflow card.
    Dashboard.broadcast_event(
      "wf-#{run.id}-build",
      %Event.ToolCall{
        harness: :fake,
        name: "Bash",
        input: %{"command" => "ls"},
        raw: %{"adw_step" => "build"}
      },
      7
    )

    # The tool event lands as a square (🛠️ icon) inside the ADW card.
    assert wait_render(view, "cns-square--tool")
    html = render(view)
    assert html =~ "workflow-#{run.id}"
    assert html =~ "🛠️"

    # Clicking the square opens the slide-out detail panel.
    view |> element("#workflow-runs button[phx-click=open_event]") |> render_click()
    assert has_element?(view, "#event-detail-panel")
  end

  test "live title broadcast upgrades the heuristic card title in place", %{conn: conn} do
    {wf, run} = seed_run(%{name: "orch-adw-#{uniq()}"})

    {:ok, view, _html} = live(conn, ~p"/")
    to_adws(view)

    # Before: the machine name is not shown as the title; the humanized type is.
    assert render(view) =~ "Plan Build"

    # The humanizer persists + broadcasts a friendly title; the open card swaps it in.
    Dashboard.broadcast_workflow_title(wf.id, "Fix Login Timeout")

    assert wait_render(view, "Fix Login Timeout")
    assert render(view) =~ "workflow-#{run.id}"
  end
end
