defmodule RepoBuilderWeb.TestHoldingStatusTest do
  @moduledoc """
  Integration proof (issue holding-status-for-blocked-agents) that a worker which stops
  HELD pending external input renders a distinct "Holding" status in the console — NOT
  "Succeeded". A worker terminal `%Event.Done{ok: true, reason: :held_pending_input}` is
  driven through the console's PubSub feed exactly as the §6 runtime broadcasts it, and the
  agent swimlane's status is asserted via the card's `data-run-status` attribute.

  This fails before the fix (the Done handler mapped `ok: true` → `:succeeded`) and passes
  after. `async: false` (shared Ecto sandbox), mirroring the other console tests.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard
  alias RepoBuilder.Harness.Event

  defp done(reason) do
    %Event.Done{harness: :claude, ok: true, reason: reason, final_text: "stopped"}
  end

  test "a held worker terminal renders Holding, not Succeeded", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    agent_id = "orch-hold-#{System.unique_integer([:positive])}"
    Dashboard.broadcast_event(agent_id, done(:held_pending_input))

    # Force the LiveView to drain the broadcast before asserting.
    _ = render(view)

    # The agent swimlane card carries its status on `data-run-status` — it is :holding,
    # never :succeeded.
    assert has_element?(view, "#swimlane-#{agent_id}[data-run-status=holding]")
    refute has_element?(view, "#swimlane-#{agent_id}[data-run-status=succeeded]")

    # And the human-visible badge says "holding", not "succeeded".
    html = render(view)
    assert html =~ "holding"
  end

  test "a normal successful worker terminal still renders Succeeded (regression)", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    agent_id = "orch-ok-#{System.unique_integer([:positive])}"
    Dashboard.broadcast_event(agent_id, done(:success))

    _ = render(view)

    assert has_element?(view, "#swimlane-#{agent_id}[data-run-status=succeeded]")
    refute has_element?(view, "#swimlane-#{agent_id}[data-run-status=holding]")
  end
end
