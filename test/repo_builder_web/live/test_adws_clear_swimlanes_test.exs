defmodule RepoBuilderWeb.TestAdwsClearSwimlanesTest do
  @moduledoc """
  LiveView integration test for the ADWS CLEAR button swimlane fix
  (specs/issue-adws-clear-button-grayed-sdlc_planner-clear-agent-swimlanes.md).

  Bug: the `#clear-workflows` button was disabled whenever only agent swimlane cards
  were on screen (no finished workflows), because its disabled predicate only considered
  `@workflow_progress` and ignored `@swimlanes` (derived from `@event_buffer`).

  These tests reproduce the bug (disabled button with clearable swimlanes) and prove
  the fix (button enabled + swimlane card removed on click + DB soft-hide for durability).

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard, Logs}
  alias RepoBuilder.Harness.Event

  defp uniq, do: System.unique_integer([:positive])

  defp wait_render(view, substring, attempts \\ 100) do
    cond do
      render(view) =~ substring -> true
      attempts > 0 -> Process.sleep(20) && wait_render(view, substring, attempts - 1)
      true -> false
    end
  end

  # ---------------------------------------------------------------------------
  # Test 1 — regression guard: button disabled when the view is empty
  # ---------------------------------------------------------------------------

  test "CLEAR is disabled when no agents or workflows are present", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()

    # No agents, no events → button must be disabled and empty-state placeholder shown.
    refute has_element?(view, "#clear-workflows:not([disabled])")
    assert has_element?(view, "#no-adws")
  end

  # ---------------------------------------------------------------------------
  # Test 2 — core fix: button enables when a non-running swimlane is present
  # ---------------------------------------------------------------------------

  test "CLEAR enables when a non-running agent swimlane is on screen (the bug fix)",
       %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "idle-agent-#{uniq()}",
        harness: "fake",
        provider: "anthropic"
      })

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()

    # Broadcast an event for the idle agent → swimlane card appears.
    Dashboard.broadcast_event(agent.id, %Event.TextDelta{harness: :fake, text: "evt"})
    assert wait_render(view, "swimlane-#{agent.id}")

    # BUG BEFORE FIX: button was disabled (only considered workflow_progress).
    # After fix: any_clearable_swimlanes?/1 returns true → button is enabled.
    assert has_element?(view, "#clear-workflows:not([disabled])")

    render_click(view, "clear_workflows")

    # Swimlane card is removed; empty-state placeholder appears.
    refute has_element?(view, "#swimlane-#{agent.id}")
    assert has_element?(view, "#no-adws")
  end

  # ---------------------------------------------------------------------------
  # Test 3 — durability: DB rows are soft-hidden so the clear survives reconnect
  # ---------------------------------------------------------------------------

  test "CLEAR soft-hides the worker's logs in the DB so the clear survives reconnect",
       %{conn: conn} do
    {:ok, agent} =
      Agents.create_agent(%{
        name: "dur-agent-#{uniq()}",
        harness: "fake",
        provider: "anthropic"
      })

    marker = "marker-#{uniq()}"

    {:ok, _log} =
      Logs.persist_event(
        %Event.TextDelta{harness: :fake, text: marker},
        %{agent_id: agent.id, session_id: "s-#{uniq()}"}
      )

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()

    Dashboard.broadcast_event(agent.id, %Event.TextDelta{harness: :fake, text: marker})
    assert wait_render(view, "swimlane-#{agent.id}")

    render_click(view, "clear_workflows")

    # The persisted row is now soft-hidden — won't reappear on reconnect
    # (backfill_events reads list_recent_global which respects the hidden flag).
    payloads = Logs.list_recent_global(500, false) |> Enum.map(& &1.payload["text"])
    refute marker in payloads
  end

  # ---------------------------------------------------------------------------
  # Test 4 — running lanes survive CLEAR
  # ---------------------------------------------------------------------------

  test "CLEAR removes idle swimlanes but keeps running ones", %{conn: conn} do
    {:ok, idle_agent} =
      Agents.create_agent(%{
        name: "idle-#{uniq()}",
        harness: "fake",
        provider: "anthropic"
      })

    {:ok, running_agent} =
      Agents.create_agent(%{
        name: "run-#{uniq()}",
        harness: "fake",
        provider: "anthropic"
      })

    {:ok, running_agent} = Agents.set_status(running_agent.id, :running)

    {:ok, view, _html} = live(conn, ~p"/")
    view |> element("#view-toggle") |> render_click()

    Dashboard.broadcast_event(idle_agent.id, %Event.TextDelta{harness: :fake, text: "i"})
    Dashboard.broadcast_event(running_agent.id, %Event.TextDelta{harness: :fake, text: "r"})
    # Broadcast agent_updated to push :running status into @statuses.
    Dashboard.broadcast_agent_updated(running_agent)

    assert wait_render(view, "swimlane-#{idle_agent.id}")
    assert wait_render(view, "swimlane-#{running_agent.id}")

    render_click(view, "clear_workflows")

    # Idle swimlane is removed; running lane stays.
    refute has_element?(view, "#swimlane-#{idle_agent.id}")
    assert has_element?(view, "#swimlane-#{running_agent.id}")
  end
end
