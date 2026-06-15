defmodule RepoBuilderWeb.DashboardLiveTest do
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard

  test "renders multi-agent + multi-workflow swimlanes and replaces a lane in place", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard")

    Dashboard.broadcast_lane(%{
      id: "agent:a1",
      kind: :agent,
      label: "agent-one",
      status: :running,
      harness: "fake"
    })

    Dashboard.broadcast_lane(%{
      id: "workflow:w1",
      kind: :workflow,
      label: "plan",
      status: :running,
      harness: nil
    })

    html = render(view)
    assert html =~ "agent-one"
    assert html =~ "plan"
    assert html =~ "running"

    # Same lane id → swimlane row is REPLACED in place (running → succeeded), flat memory.
    Dashboard.broadcast_lane(%{
      id: "agent:a1",
      kind: :agent,
      label: "agent-one",
      status: :succeeded,
      harness: "fake"
    })

    html = render(view)
    assert html =~ "succeeded"
    # Exactly one row for agent:a1 (replaced, not appended).
    assert html |> String.split("lane-agent:a1") |> length() == 2
  end
end
