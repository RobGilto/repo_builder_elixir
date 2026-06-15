defmodule RepoBuilderWeb.WorkflowLiveTest do
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Dashboard, Workflows}

  defp run_fixture(status) do
    {:ok, wf} =
      Workflows.create_workflow(%{
        name: "wf-#{System.unique_integer([:positive])}",
        steps: [%{"name" => "plan", "harness" => "fake"}]
      })

    {:ok, run} = Workflows.create_run(%{workflow_id: wf.id, status: status, current_step: "plan"})
    run
  end

  test "renders run status/cost via assign_async and updates live", %{conn: conn} do
    run = run_fixture(:running)
    {:ok, view, _html} = live(conn, ~p"/workflows/#{run.id}")

    html = render_async(view)
    assert html =~ "running"

    # Live update from the runner.
    {:ok, updated} = Workflows.update_run(run, %{status: :succeeded})
    Dashboard.broadcast_workflow(run.id, {:workflow_update, updated})

    assert render(view) =~ "succeeded"
  end

  test "shows 'not found' for an unknown run", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/workflows/#{Ecto.UUID.generate()}")
    assert render_async(view) =~ "not found"
  end
end
