defmodule RepoBuilderWeb.TestPortableAdwOnAdwsScreenTest do
  @moduledoc """
  Regression test for issue-two (portable ADW invisible on the ADWs screen).

  The portable / shell-out ADW path models a run as an orchestrator-owned worker Agent
  driven by the §6 session runtime, which historically only broadcast a `kind: :agent`
  lane. The console's ADWs screen renders `kind: :workflow` cards, so the running ADW had
  no surface and the screen showed "No AI Developer Workflows found."

  The fix has `RepoBuilder.Session.Server` additionally broadcast a `kind: :workflow` lane
  (`id: "workflow:<agent_id>"`) for ADW-harness sessions. This test proves the ADWs screen
  starts empty (`#no-adws`), then renders a `#workflow-<id>` card — with squares filled from
  the already-streaming `harness: "adw"` worker events — once that lane arrives.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Event

  defp wait_render(view, substring, attempts \\ 100) do
    cond do
      render(view) =~ substring -> true
      attempts > 0 -> Process.sleep(20) && wait_render(view, substring, attempts - 1)
      true -> false
    end
  end

  defp to_adws(view), do: view |> element("#view-toggle") |> render_click()

  test "a running portable ADW surfaces as a card on the ADWs screen", %{conn: conn} do
    run_id = Ecto.UUID.generate()

    {:ok, view, _html} = live(conn, ~p"/")
    to_adws(view)

    # Before any workflow lane: the ADWs screen shows the empty state and no card.
    assert has_element?(view, "#no-adws")
    refute has_element?(view, "#workflow-#{run_id}")

    # The §6 runtime broadcasts a `kind: :workflow` lane for the ADW-harness session
    # (id == the worker/agent id) as it transitions to running.
    Dashboard.broadcast_lane(%{
      id: "workflow:#{run_id}",
      kind: :workflow,
      label: "plan",
      status: :running,
      harness: "adw"
    })

    # The ADW worker's per-step events stream through the same console feed, keyed to the
    # run id — filling the card's step squares (`agent_key == run_id`).
    Dashboard.broadcast_event(
      run_id,
      %Event.ToolCall{
        harness: :adw,
        name: "Bash",
        input: %{"command" => "ls"},
        raw: %{"adw_step" => "plan"}
      },
      42
    )

    # After the lane: an ADW card renders and the empty state is gone.
    assert wait_render(view, "workflow-#{run_id}")
    assert has_element?(view, "#workflow-#{run_id}")
    refute has_element?(view, "#no-adws")
  end
end
