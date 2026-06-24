defmodule RepoBuilderWeb.TestOrchestratorChatWorkerIsolationTest do
  @moduledoc """
  Regression test for the bug where worker-agent messages leaked into the
  right-hand orchestrator CHAT pane
  (specs/issue-NA-adw-NA-sdlc_planner-fix-orchestrator-chat-shows-worker-messages.md).

  The chat pane is orchestrator ↔ user only. Orchestrator turns broadcast under an
  `"orch-<orchestrator_id>-<n>"` agent_id (orchestrator/server.ex:85,113); worker
  DB agents broadcast under their Ecto UUID (never `"orch-"`). Worker text must stay
  in the center EVENT STREAM (attributed per-agent), not the chat. This asserts the
  three chat surfaces — finalized text, in-flight streaming, and reconnect backfill —
  all gate on the orchestrator-source predicate.

  Events are pushed onto the global `console:events` feed via
  `Dashboard.broadcast_event/2`; the ~50 ms flush tick is driven deterministically by
  sending `:flush_stream` to the view. `async: false` matches the other console tests
  (shared Ecto sandbox).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Dashboard, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event

  # Flush the throttled streaming buffer deterministically, then drain the mailbox.
  defp flush(view) do
    send(view.pid, :flush_stream)
    render(view)
  end

  test "finalized worker text stays out of the chat but shows in the event stream",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    # The chat pane is scoped to the ACTIVE orchestrator (the platform default on a
    # no-project mount), so the orchestrator turn must broadcast under its id.
    {:ok, default} = Orchestrators.get_or_create_default()
    orch_id = "orch-#{default.id}-1"
    worker_id = Ecto.UUID.generate()

    Dashboard.broadcast_event(orch_id, %Event.TextDelta{
      harness: :fake,
      text: "orchestrator hello"
    })

    Dashboard.broadcast_event(worker_id, %Event.TextDelta{
      harness: :fake,
      text: "crud-debugger worker output"
    })

    # Drain the LiveView mailbox (FIFO) before asserting on the resulting DOM.
    _ = render(view)

    # The orchestrator's text is the only chat bubble.
    assert has_element?(view, ".cns-bubble--orch", "orchestrator hello")
    refute has_element?(view, ".cns-bubble--orch", "crud-debugger worker output")

    # The worker text is NOT lost — it remains visible (attributed) in the center stream.
    assert has_element?(view, "#event-stream", "crud-debugger worker output")
  end

  test "only the orchestrator's in-flight streaming bubble renders in the chat",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    {:ok, default} = Orchestrators.get_or_create_default()
    orch_id = "orch-#{default.id}-1"
    worker_id = Ecto.UUID.generate()

    Dashboard.broadcast_event(worker_id, %Event.TextDelta{
      harness: :fake,
      text: "worker streaming",
      partial?: true
    })

    Dashboard.broadcast_event(orch_id, %Event.TextDelta{
      harness: :fake,
      text: "orchestrator streaming",
      partial?: true
    })

    _ = flush(view)

    # Only the orchestrator's live bubble exists; the worker partial built no buffer.
    assert has_element?(view, "#streaming-text-#{orch_id}", "orchestrator streaming")
    refute has_element?(view, "#streaming-text-#{worker_id}")
    refute has_element?(view, ".cns-bubble--streaming", "worker streaming")
  end

  test "reconnect backfill reconstructs only orchestrator text into the chat",
       %{conn: conn} do
    # Backfill is scoped to the ACTIVE orchestrator (the platform default on a
    # no-project mount), so the orchestrator turn must be persisted under it to be
    # reconstructed into the chat on reconnect.
    {:ok, orch} = Orchestrators.get_or_create_default()

    {:ok, worker} =
      Agents.create_agent(%{
        name: "worker-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    # Persist one orchestrator turn (under session_id "orch-…") and one worker turn
    # (under its agent_id), the way the runtime does, so a fresh mount backfills both
    # from `list_recent_global/1`.
    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.TextDelta{harness: :fake, text: "orchestrator persisted reply"},
        %{orchestrator_id: orch.id, session_id: "orch-#{orch.id}-1"}
      )

    {:ok, _} =
      Logs.persist_event(
        %Event.TextDelta{harness: :fake, text: "worker persisted output"},
        %{agent_id: worker.id, session_id: "fake-session"}
      )

    {:ok, view, _html} = live(conn, ~p"/")

    # Only the orchestrator's persisted text reconstructs into the chat; the worker's
    # text is reconstructed into the center stream, not the chat.
    assert has_element?(view, ".cns-bubble--orch", "orchestrator persisted reply")
    refute has_element?(view, ".cns-bubble--orch", "worker persisted output")
    assert has_element?(view, "#event-stream", "worker persisted output")
  end
end
