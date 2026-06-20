defmodule RepoBuilderWeb.TestOrchestratorThinkingAnimationTest do
  @moduledoc """
  Integration test for the orchestrator "thinking" animation in the command panel
  (see specs/issue-the-adw-directory-sdlc_planner-orchestrator-thinking-animation.md).

  The header `activity_orb` (variant `:orchestrator`) and the chat-log `typing_indicator`
  must animate for the full duration a turn is in flight, driven off the authoritative
  `@orchestrator_queue.busy?` signal — the same snapshot that renders the queued-messages
  busy badge. We drive that signal over the queue-snapshot PubSub seam
  (`{:orchestrator_queue, id, snapshot}`) the LiveView already subscribes to, then assert
  the orb + typing indicator appear while busy and clear when the queue drains.

  `async: false` so the shared Ecto sandbox reaches the LiveView process.
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.Dashboard

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(20) && wait_until(fun, attempts - 1)
      true -> false
    end
  end

  test "the command panel animates while the orchestrator queue is busy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    orchestrator_id = :sys.get_state(view.pid).socket.assigns.orchestrator_id
    assert orchestrator_id

    # Idle: no orb, no typing indicator.
    refute has_element?(view, "#command-panel .cns-orb--orchestrator")
    refute has_element?(view, "#typing-indicator")

    # A turn starts: the queue snapshot flips busy? true (covering the thinking gap
    # before any text streams).
    Dashboard.broadcast_orchestrator_queue(orchestrator_id, %{
      busy?: true,
      current: "orch-#{orchestrator_id}-1",
      queued: [],
      depth: 0
    })

    assert wait_until(fn ->
             has_element?(
               view,
               ~s(#command-panel [data-orb][data-active="true"].cns-orb--orchestrator)
             ) and
               has_element?(view, "#typing-indicator")
           end)

    # The turn completes: the queue drains and the animation clears.
    Dashboard.broadcast_orchestrator_queue(orchestrator_id, %{
      busy?: false,
      current: nil,
      queued: [],
      depth: 0
    })

    assert wait_until(fn ->
             not has_element?(view, "#command-panel .cns-orb--orchestrator") and
               not has_element?(view, "#typing-indicator")
           end)
  end
end
