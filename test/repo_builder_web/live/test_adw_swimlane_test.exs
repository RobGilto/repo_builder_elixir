defmodule RepoBuilderWeb.TestAdwSwimlaneTest do
  @moduledoc """
  LiveView test for the rich per-step ADW swimlane in the console ADWS view
  (BUILD_PROMPT.md §9): a seeded `WorkflowRun` with `step_states` renders per-step
  squares carrying each step's status, and a live `{:workflow_step, ...}` broadcast
  on the lanes topic updates the lane in place.

  `async: false` so the shared Ecto sandbox reaches the LiveView process and the
  broadcasts land in order.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Dashboard, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  defp seed_run do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "wf-#{uniq()}",
        type: "plan_build",
        steps: [
          %{"name" => "plan", "harness" => "fake", "on_success" => "build"},
          %{"name" => "build", "harness" => "fake", "on_success" => "done"}
        ]
      })

    {:ok, run} =
      Workflows.create_run(%{workflow_id: wf.id, status: :running, current_step: "plan"})

    {:ok, run} = Workflows.put_step_state(run, "plan", %{status: "succeeded"})
    {:ok, run} = Workflows.put_step_state(run, "build", %{status: "running"})
    run
  end

  test "renders per-step squares with per-step status and updates live", %{conn: conn} do
    run = seed_run()

    {:ok, view, _html} = live(conn, ~p"/")

    # Switch to the ADWS view.
    view |> element("#view-toggle") |> render_click()

    html = render(view)
    # The run renders as a per-step swimlane with one square per step, each carrying
    # its per-step status as a data attribute.
    assert html =~ "workflow-#{run.id}"
    assert html =~ ~s(data-step-status="succeeded")
    assert html =~ ~s(data-step-status="running")

    # A live per-step broadcast (as both engines emit) flips `build` to succeeded.
    {:ok, run} = Workflows.put_step_state(run, "build", %{status: "succeeded"})
    Dashboard.broadcast_workflow_step(run.id, Workflows.run_progress(run))

    html = render(view)
    refute html =~ ~s(data-step-status="running")
    # Both steps now succeeded → completed 2/2.
    assert html =~ "2/2"
  end
end
