defmodule RepoBuilderWeb.TestCustomAdwObservabilityTest do
  @moduledoc """
  Integration test for custom-ADW swimlane observability
  (specs/issue-custom-adw-observability…): a custom in-app ADW's step events now persist
  under `agent_logs.workflow_run_id`, so the ADW card's clickable event squares — and the
  human-friendly detail panel behind them — survive a reconnect / late connect, matching
  the observability standard/orchestrator ADWs already have.

  `async: false` — the spawned `Session.Server` process needs the shared Ecto sandbox
  connection, same as `RepoBuilder.SessionCase` (BUILD_PROMPT.md §13).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Logs, WorkflowEngine, Workflows}

  defp uniq, do: System.unique_integer([:positive])

  defp run_custom_workflow_to_completion do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "custom-obs-#{uniq()}",
        type: "custom",
        steps: [
          %{
            "name" => "build",
            "harness" => "fake",
            "on_success" => "done",
            "on_failure" => "abort"
          }
        ]
      })

    {:ok, run_id, pid} = WorkflowEngine.start_workflow(wf, inputs: %{"input" => "ship it"})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 8_000

    Workflows.get_run(run_id)
  end

  test "a custom ADW's step events persist under workflow_run_id, agent_id/orchestrator_id nil" do
    run = run_custom_workflow_to_completion()

    assert run.status == :succeeded

    rows =
      Logs.list_recent_global(200, false)
      |> Enum.filter(&(&1.workflow_run_id == run.id))

    assert rows != [], "expected persisted agent_logs rows for the custom workflow run"
    assert Enum.all?(rows, &(&1.agent_id == nil))
    assert Enum.all?(rows, &(&1.orchestrator_id == nil))
    assert Enum.any?(rows, &(&1.event_type == :tool_call))
  end

  test "a fresh mount (late connect) backfills the card with a clickable square under the build step, and opening it shows the friendly detail",
       %{conn: conn} do
    run = run_custom_workflow_to_completion()

    # Simulate an operator opening (or reloading) the console AFTER the run has
    # completed and gone quiet — the reconnect/late-connect path exercised by
    # `backfill_events/1`, not a continuously-connected live session.
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()

    html = render(view)
    assert html =~ "workflow-#{run.id}"

    # The persisted tool_call event landed inside the run's `build` step box (not the
    # `_workflow` catch-all), proving `workflow_step_squares/3` derives the step from the
    # `"wf-<run_id>-build"` agent key rather than the (absent) `adw_step` payload field.
    assert has_element?(
             view,
             "##{"workflow-#{run.id}"}-step-build .cns-square--tool"
           )

    view
    |> element("##{"workflow-#{run.id}"}-step-build .cns-square--tool[title^='tool_call']")
    |> render_click()

    assert has_element?(view, "#event-detail-panel")
    assert render(view) =~ "bash"
  end
end
