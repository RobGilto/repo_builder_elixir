defmodule RepoBuilderWeb.TestOrchestratorChatHistoryPersistTest do
  @moduledoc """
  Regression test for the bug where the orchestrator CHAT pane backfilled EMPTY after
  a server restart / LiveView re-mount once worker activity dominated the global event
  window (specs/issue-chat-adw-history-sdlc_planner-orchestrator-chat-history-backfill.md).

  The chat pane is ephemeral in-memory state (`@messages`), rebuilt on connect by
  `backfill_events/1`. It used to be seeded as a byproduct of the worker-dominated
  `list_recent_global/2` slice (capped at 200 rows); orchestrator rows fell out of that
  window once ≥200 worker rows existed after the last orchestrator message, so the chat
  history "disappeared" on reconnect even though it was durably persisted.

  The fix seeds the chat pane from a dedicated orchestrator-scoped query
  (`Logs.list_recent_orchestrator_messages/2`). This test persists orchestrator text,
  floods `agent_logs` with >200 later worker rows, mounts ConsoleLive, and asserts the
  orchestrator chat survives — and that worker text never leaks into the chat.

  `async: false` matches the other console tests (shared Ecto sandbox).
  """
  use RepoBuilderWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias RepoBuilder.{Agents, Logs, Orchestrators}
  alias RepoBuilder.Harness.Event

  test "orchestrator chat survives a flood of >200 later worker rows on backfill",
       %{conn: conn} do
    # Persist to the ACTIVE orchestrator (the platform default on a no-project mount):
    # the chat backfill is now scoped to the active brain (issue-conversation-history-scope).
    {:ok, orch} = Orchestrators.get_or_create_default()

    {:ok, worker} =
      Agents.create_agent(%{
        name: "worker-#{System.unique_integer([:positive])}",
        harness: "fake",
        provider: "anthropic"
      })

    # Persist the orchestrator turn FIRST so it is the oldest row. NOTE: the real
    # persisted shape is `agent_id: nil`, `orchestrator_id` set, and `session_id` a plain
    # HARNESS session UUID — NOT the live `"orch-…"` broadcast key. Using a non-`orch-`
    # session_id here is load-bearing: it forces the backfill to recover the orchestrator
    # identity from `orchestrator_id` (log_to_row/4), the actual fix. An `"orch-…"`
    # session_id would mask the bug (the old agent_id||session_id derivation would pass).
    {:ok, _} =
      Logs.persist_orchestrator_event(
        %Event.TextDelta{harness: :fake, text: "orchestrator durable reply"},
        %{orchestrator_id: orch.id, session_id: Ecto.UUID.generate()}
      )

    # Then flood the table with >200 LATER worker rows so the orchestrator row is pushed
    # out of the most-recent-200 global window (the bug's trigger condition).
    for n <- 1..250 do
      {:ok, _} =
        Logs.persist_event(
          %Event.TextDelta{harness: :fake, text: "worker output #{n}"},
          %{agent_id: worker.id, session_id: "fake-session"}
        )
    end

    # Sanity: the orchestrator row is NO LONGER in the global-200 slice (bug condition),
    # but IS returned by the orchestrator-scoped query (the fix's source).
    assert Logs.list_recent_global(200, false)
           |> Enum.filter(& &1.orchestrator_id) == []

    assert Logs.list_recent_orchestrator_messages(100, false)
           |> Enum.any?(&(&1.payload["text"] == "orchestrator durable reply"))

    {:ok, view, _html} = live(conn, ~p"/")

    # The orchestrator chat reconstructs even though it is outside the global window.
    assert has_element?(view, ".cns-bubble--orch", "orchestrator durable reply")

    # Control: worker text never appears in the chat pane (orchestrator-only gate holds).
    refute has_element?(view, ".cns-bubble--orch", "worker output")
  end
end
